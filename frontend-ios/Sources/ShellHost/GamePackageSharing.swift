import Foundation
import CryptoKit
import Security
import X509
import NIOSSL
import Vapor
import Darwin

/// A QR is a short-lived invitation, not a public download link. Only its address
/// goes over the network. The fragment carries the TLS pin and access token.
public struct GamePackageShareInvitation: Sendable {
    let address: URL
    let pin: String
    let token: String

    public init(url: URL) throws {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, Self.isLAN(host),
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.path == "/nxb/1", let fragment = parts.fragment else {
            throw GamePackageError.invalid("invalid sharing invitation")
        }
        let fields = fragment.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 2, fields.allSatisfy({ $0.count == 64 && $0.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) }) else {
            throw GamePackageError.invalid("invalid sharing credentials")
        }
        pin = String(fields[0]); token = String(fields[1])
        parts.fragment = nil
        guard let address = parts.url else { throw GamePackageError.invalid("invalid sharing address") }
        self.address = address
    }

    // No DNS rebinding, internet listener or cloud relay in this LAN-only flow.
    static func isLAN(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4, zip(parts, octets).allSatisfy({ String($0.1) == $0.0 }) else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
    }
}

public actor GamePackageShareServer {
    private var application: Application?
    private var leasedDirectory: URL?
    private var starting = false
    private var cancelled = false
    static let chunkSize = 1 << 20

    public init() {}

    deinit {
        if let app = application {
            let directory = leasedDirectory
            Task {
                try? await app.asyncShutdown()
                if let directory { GamePackageLibrary.releaseSharing(directory) }
            }
        }
    }

    /// Retains this installed generation across library cleanup in all windows.
    /// Caller stops when the sheet dismisses or the app leaves the foreground.
    public func start(directory: URL) async throws -> URL {
        guard application == nil, !starting else { throw GamePackageError.invalid("sharing already active") }
        starting = true; cancelled = false
        defer { starting = false }
        GamePackageLibrary.retainSharing(directory)
        var retained = false
        defer { if !retained { GamePackageLibrary.releaseSharing(directory) } }
        let source = try ShareSource(directory: directory)
        let host = try Self.localAddress()
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("NX2Apple local transfer") }
        let now = Date()
        let certificate = try Certificate(version: .v3,
            serialNumber: .init(bytes: SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }),
            publicKey: .init(key.publicKey), notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(86400), issuer: name, subject: name,
            signatureAlgorithm: .ecdsaWithSHA256, extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
            }, issuerPrivateKey: .init(key))
        let certificatePEM = try certificate.serializeAsPEM().pemString
        let tlsCertificate = try NIOSSLCertificate(bytes: Array(certificatePEM.utf8), format: .pem)
        let pin = Self.digest(Data(try tlsCertificate.toDERBytes()))
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Self.hex(Data($0)) }
        let app = try await Application.make(.production)
        do {
            app.logger.logLevel = .critical
            app.middleware = .init() // No request logging of invitation credentials.
            var tls = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(tlsCertificate)],
                privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)))
            tls.minimumTLSVersion = .tlsv12
            app.http.server.configuration.tlsConfiguration = tls
            app.http.server.configuration.hostname = host
            app.http.server.configuration.port = 0
            app.routes.defaultMaxBodySize = "1kb"
            let expires = now.addingTimeInterval(3600)
            app.get("nxb", "1", "metadata", ":kind") { request async throws -> Response in
                try Self.authorize(request, token: token, expires: expires)
                let bytes: Data
                switch request.parameters.get("kind") {
                case "manifest": bytes = source.manifestBytes
                case "proof": bytes = source.proof ?? Data()
                default: throw Abort(.notFound)
                }
                return Self.response(bytes)
            }
            app.get("nxb", "1", "file", ":index", ":offset") { request async throws -> Response in
                try Self.authorize(request, token: token, expires: expires)
                guard let index = request.parameters.get("index", as: Int.self),
                      let offset = request.parameters.get("offset", as: UInt64.self) else { throw Abort(.badRequest) }
                let bytes = try await Task.detached { try source.read(index: index, offset: offset) }.value
                return Self.response(bytes)
            }
            try await app.server.start(address: nil)
            guard !cancelled, let port = app.http.server.shared.localAddress?.port,
                  let url = URL(string: "https://\(host):\(port)/nxb/1#\(pin).\(token)") else {
                throw CancellationError()
            }
            application = app
            leasedDirectory = directory
            retained = true
            return url
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    public func stop() async {
        cancelled = true
        guard let app = application else { return }
        application = nil
        let directory = leasedDirectory
        leasedDirectory = nil
        try? await app.asyncShutdown()
        if let directory { GamePackageLibrary.releaseSharing(directory) }
    }

    private static func authorize(_ request: Request, token: String, expires: Date) throws {
        guard Date() < expires, let supplied = request.headers.bearerAuthorization?.token,
              digest(Data(supplied.utf8)) == digest(Data(token.utf8)) else { throw Abort(.unauthorized) }
    }

    private static func response(_ data: Data) -> Response {
        Response(status: .ok, headers: ["Content-Type": "application/octet-stream", "Cache-Control": "no-store"], body: .init(data: data))
    }

    static func digest(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func localAddress() throws -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw GamePackageError.invalid("local network unavailable") }
        defer { freeifaddrs(interfaces) }
        var item = interfaces
        while let current = item {
            defer { item = current.pointee.ifa_next }
            let interface = current.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let host = String(cString: buffer)
                if GamePackageShareInvitation.isLAN(host) { return host }
            }
        }
        throw GamePackageError.invalid("connect to a local network to share")
    }
}

private struct ShareSource: Sendable {
    let directory: URL
    let legacyArchive: URL?
    let legacyEntries: [String: (start: UInt64, bytes: UInt64)]
    let legacySize: UInt64
    let manifestBytes: Data
    let proof: Data?
    let manifest: GamePackageManifest

    init(directory: URL) throws {
        self.directory = directory
        let archive = directory.appendingPathComponent("original.nxb")
        if FileManager.default.fileExists(atPath: archive.path) {
            let reader = try NXBArchive.Reader(archive)
            defer { try? reader.input.close() }
            guard let entry = reader.entries["nxb.json"], entry.bytes <= NXBArchive.metadataLimit else {
                throw GamePackageError.invalid("sharing manifest missing")
            }
            manifestBytes = try reader.read(entry.start, Int(entry.bytes))
            if let entry = reader.entries["nxb.signature.json"] {
                guard entry.bytes <= 64 << 10 else { throw GamePackageError.invalid("sharing proof too large") }
                proof = try reader.read(entry.start, Int(entry.bytes))
            } else { proof = nil }
            legacyArchive = archive
            legacyEntries = reader.entries.mapValues { ($0.start, $0.bytes) }
            legacySize = reader.size
        } else {
            manifestBytes = try Self.metadata(directory.appendingPathComponent("nxb.json"))
            let url = directory.appendingPathComponent("nxb.signature.json")
            proof = FileManager.default.fileExists(atPath: url.path) ? try Self.metadata(url) : nil
            guard (proof?.count ?? 0) <= 64 << 10 else { throw GamePackageError.invalid("sharing proof too large") }
            legacyArchive = nil
            legacyEntries = [:]
            legacySize = 0
        }
        manifest = try JSONDecoder().decode(GamePackageManifest.self, from: manifestBytes)
        try manifest.validate()
    }

    private static func metadata(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: NXBArchive.metadataLimit + 1) ?? Data()
        guard bytes.count <= NXBArchive.metadataLimit else { throw GamePackageError.invalid("sharing metadata too large") }
        return bytes
    }

    func read(index: Int, offset: UInt64) throws -> Data {
        guard manifest.files.indices.contains(index) else { throw Abort(.notFound) }
        let file = manifest.files[index]
        guard offset < file.bytes else { throw Abort(.rangeNotSatisfiable) }
        let count = Int(min(UInt64(GamePackageShareServer.chunkSize), file.bytes - offset))
        if let legacyArchive {
            guard let entry = legacyEntries[file.path], entry.bytes == file.bytes else { throw Abort(.conflict) }
            let handle = try FileHandle(forReadingFrom: legacyArchive)
            defer { try? handle.close() }
            guard try handle.seekToEnd() == legacySize else { throw Abort(.conflict) }
            try handle.seek(toOffset: entry.start + offset)
            let bytes = try handle.read(upToCount: count) ?? Data()
            guard bytes.count == count else { throw Abort(.conflict) }
            return bytes
        }
        let url = GamePackage.transportFile(file, in: directory)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw Abort(.forbidden) }
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        guard try handle.seekToEnd() == file.bytes else { throw Abort(.conflict) }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: count) ?? Data()
        guard bytes.count == count else { throw Abort(.conflict) }
        return bytes
    }
}

public actor GamePackageShareClient {
    private let invitation: GamePackageShareInvitation
    private let session: URLSession
    private var metadata: (Data, Data?, GamePackage.Preview)?

    public init(url: URL) throws {
        let invitation = try GamePackageShareInvitation(url: url)
        self.invitation = invitation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration,
            delegate: ShareTrust(pin: invitation.pin, host: invitation.address.host!, port: invitation.address.port!),
            delegateQueue: nil)
    }

    public func preview() async throws -> GamePackage.Preview {
        if let metadata { return metadata.2 }
        let raw = try await get("metadata/manifest", maximum: NXBArchive.metadataLimit)
        let manifest = try JSONDecoder().decode(GamePackageManifest.self, from: raw)
        try manifest.validate()
        let proofBytes = try await get("metadata/proof", maximum: 64 << 10)
        let proof = proofBytes.isEmpty ? nil : proofBytes
        let publisher = try proof.map { try GamePackageSignature.verify(manifest: raw, proof: $0) }
        var cover: Data?
        if let index = manifest.files.firstIndex(where: { $0.path == "run/icon.jpg" && $0.bytes <= 4 << 20 }) {
            var data = Data()
            let file = manifest.files[index]
            while data.count < file.bytes {
                let chunk = try await get("file/\(index)/\(data.count)", maximum: GamePackageShareServer.chunkSize)
                guard !chunk.isEmpty, UInt64(data.count + chunk.count) <= file.bytes else { throw GamePackageError.invalid("invalid shared cover") }
                data.append(chunk)
            }
            guard GamePackageShareServer.digest(data) == file.sha256 else { throw GamePackageError.invalid("shared cover checksum") }
            cover = data
        }
        let preview = GamePackage.Preview(manifest: manifest, publisher: publisher, cover: cover,
            manifestSHA256: GamePackageShareServer.digest(raw))
        metadata = (raw, proof, preview)
        return preview
    }

    /// Staging is private and cannot launch. Present the verified preview before
    /// asking the library to sign locally and activate this directory.
    public func receive(in root: URL, progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws -> URL {
        _ = try await preview()
        guard let (raw, proof, preview) = metadata else { throw GamePackageError.invalid("missing sharing metadata") }
        let directory = root.appendingPathComponent(".nxb-\(UUID().uuidString.lowercased())", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try raw.write(to: directory.appendingPathComponent("nxb.json"), options: .atomic)
            if let proof { try proof.write(to: directory.appendingPathComponent("nxb.signature.json"), options: .atomic) }
            let total = preview.manifest.files.reduce(UInt64(0)) { $0 + $1.bytes }
            var received: UInt64 = 0
            for (index, file) in preview.manifest.files.enumerated() {
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent(file.path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: destination.path, contents: nil) else { throw GamePackageError.invalid("could not create received file") }
                let handle = try FileHandle(forWritingTo: destination)
                do {
                    var offset: UInt64 = 0
                    var hash = SHA256()
                    while offset < file.bytes {
                        try Task.checkCancellation()
                        let count = Int(min(UInt64(GamePackageShareServer.chunkSize), file.bytes - offset))
                        let bytes = try await get("file/\(index)/\(offset)", maximum: count)
                        guard bytes.count == count else { throw GamePackageError.invalid("incomplete shared file") }
                        try handle.write(contentsOf: bytes)
                        hash.update(data: bytes)
                        offset += UInt64(count); received += UInt64(count)
                        progress(received, total)
                    }
                    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                        throw GamePackageError.invalid("shared file checksum mismatch")
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
            }
            return directory
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    deinit { session.invalidateAndCancel() }

    public func cancel() { session.invalidateAndCancel() }

    private func get(_ path: String, maximum: Int) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: invitation.address.appendingPathComponent(path))
        request.setValue("Bearer \(invitation.token)", forHTTPHeaderField: "Authorization")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= maximum else { throw GamePackageError.invalid("sharing session ended or request rejected") }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < maximum else { throw GamePackageError.invalid("shared response too large") }
            bytes.append(byte)
        }
        return bytes
    }
}

private final class ShareTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    let pin: String
    let host: String
    let port: Int
    init(pin: String, host: String, port: Int) { self.pin = pin; self.host = host; self.port = port }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == host, space.port == port, let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              GamePackageShareServer.digest(SecCertificateCopyData(leaf) as Data) == pin else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // This session trusts only the exact ephemeral certificate shown in the
        // scanned QR, not arbitrary self-signed certificates or the system store.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
