#if targetEnvironment(macCatalyst)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Darwin
import ShellHost

/// A foreground Terminal sharing session. Only requested stdout invitations
/// contain credentials; diagnostic stderr and error events never include URLs.
@MainActor enum CatalystShareCommand {
    private static let lifetimeSeconds = 3600

    static func run(directory: URL, archive: URL? = nil, remote: Bool, json: Bool) async -> Int32 {
        let server: GamePackageShareServer
        if remote {
            #if canImport(GameTunnelC)
            server = GamePackageShareServer(tunnel: GameTunnel())
            #else
            reportError("remote_unavailable", "External sharing is not available in this build.", json: json)
            return 1
            #endif
        } else {
            server = GamePackageShareServer()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(lifetimeSeconds))
        do {
            try Task.checkCancellation()
            if remote {
                write("External sharing uses Cloudflare, which can read game data. Anyone with the link can download it.", to: .standardError)
            }
            let plain = try await server.start(directory: directory, remote: remote, archive: archive)
            try Task.checkCancellation()
            let app = try GamePackageReceiveLink.appURL(for: plain)
            if json {
                try emit(["event": "sharing", "url": plain.absoluteString, "appURL": app.absoluteString,
                      "remote": remote, "maximumLifetimeSeconds": lifetimeSeconds])
            } else {
                try deliver("Share link:")
                try deliver(plain.absoluteString)
                try deliver("Open in NX2Apple:")
                try deliver(app.absoluteString)
                if isatty(STDOUT_FILENO) == 1 {
                    if let qr = terminalQR(app) { try deliver(qr) }
                    else { write("QR cannot fit this Terminal window. Widen it and restart sharing, or use the link above.", to: .standardError) }
                }
                write("Sharing for up to one hour. Keep this command running; press Ctrl-C to stop.", to: .standardError)
            }
            try await clock.sleep(until: deadline)
            await server.stop()
            reportStopped("expired", json: json)
            return 0
        } catch {
            // Always await cleanup before returning, including cancellation during
            // startup. No detached cleanup races command exit or source removal.
            await server.stop()
            if error is CancellationError || Task.isCancelled {
                reportStopped("cancelled", json: json)
                return 130
            }
            reportError("sharing_failed", "Sharing could not start or continue. Check the package and network connection.", json: json)
            return 1
        }
    }

    /// Two vertical QR modules per text cell preserve square module geometry in
    /// a normal monospace Terminal. ANSI pins black-on-white independently of theme.
    /// A four-module quiet zone is emitted on every side; never wrap QR rows.
    private static func terminalQR(_ url: URL) -> String? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, width <= 512, height <= 512 else { return nil }
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0,
              Int(size.ws_col) > width + 8 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            CIContext().render(output, toBitmap: base, rowBytes: width, bounds: extent,
                               format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        func dark(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            // Core Image bitmap coordinates begin at the bottom-left.
            return pixels[(height - 1 - y) * width + x] < 128
        }
        var lines: [String] = []
        for y in stride(from: -4, to: height + 4, by: 2) {
            var line = "\u{1B}[38;2;0;0;0;48;2;255;255;255m"
            for x in -4..<(width + 4) {
                switch (dark(x, y), dark(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }

    private static func reportStopped(_ reason: String, json: Bool) {
        if json { try? emit(["event": "sharing_stopped", "reason": reason]) }
        else { write(reason == "expired" ? "Sharing expired and stopped." : "Sharing stopped.", to: .standardError) }
    }
    private static func reportError(_ code: String, _ message: String, json: Bool) {
        if json { try? emit(["event": "error", "code": code, "message": message]) }
        else { write(message, to: .standardError) }
    }
    private static func emit(_ fields: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    private static func deliver(_ text: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }
    private static func write(_ text: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data((text + "\n").utf8))
    }
}
#endif
