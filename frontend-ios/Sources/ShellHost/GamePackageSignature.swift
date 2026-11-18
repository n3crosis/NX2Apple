import CryptoKit
import Foundation
import Security

/// A valid publisher signature proves possession of the certificate's key, not
/// trust in its claimed subject or permission to load its code on iOS.
public struct GamePackagePublisher: Sendable {
    public let keyID: String
    public let certificateSHA256: String?
    public let trusted: Bool
    public let subject: String?
    public let expiresAt: Date?
}

public enum GamePackageSignature {
    private struct Envelope: Codable {
        let version: Int
        let algorithm: String
        let keyID: String
        let certificate: String?
        let signature: String
    }

    /// Signs package metadata only. The envelope contains the public certificate,
    /// never the identity or its private key. File hashes in the manifest cover data.
    static func sign(manifest: Data, identity: SecIdentity) throws -> Data {
        guard !manifest.isEmpty, manifest.count <= NXBArchive.metadataLimit else {
            throw GamePackageError.invalid("publisher manifest size")
        }
        var certificate: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess,
              let certificate, let key else {
            throw GamePackageError.invalid("publisher identity unavailable")
        }
        let der = SecCertificateCopyData(certificate) as Data
        let keyID = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        var message = Data(("NXB-PACKAGE-SIGNATURE-V1\n" + keyID + "\n").utf8)
        message.append(manifest)
        let algorithm: SecKeyAlgorithm
        let name: String
        if SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256) {
            algorithm = .rsaSignatureMessagePKCS1v15SHA256; name = "RS256"
        } else {
            algorithm = .ecdsaSignatureMessageX962SHA256; name = "ES256"
        }
        guard SecKeyIsAlgorithmSupported(key, .sign, algorithm),
              let signed = SecKeyCreateSignature(key, algorithm, message as CFData, nil) as Data? else {
            throw GamePackageError.invalid("publisher signing failed")
        }
        let signature = name == "ES256"
            ? try P256.Signing.ECDSASignature(derRepresentation: signed).rawRepresentation : signed
        let proof = try JSONEncoder().encode(Envelope(version: 1, algorithm: name, keyID: keyID,
            certificate: der.base64EncodedString(), signature: signature.base64EncodedString()))
        _ = try verify(manifest: manifest, proof: proof)
        return proof
    }

    /// Personal/self-signed and expired certificates are accepted as public-key
    /// containers. Trust comes only from fingerprints the host already knows.
    /// This does not perform WebPKI validation or Apple native code signing.
    public static func verify(manifest: Data, proof: Data,
                              trustedCertificates: Set<String> = [],
                              pinnedKeys: [String: Data] = [:]) throws -> GamePackagePublisher {
        guard !manifest.isEmpty, manifest.count <= NXBArchive.metadataLimit,
              !proof.isEmpty, proof.count <= 64 << 10 else {
            throw GamePackageError.invalid("publisher proof size")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: proof)
        guard envelope.version == 1, validKeyID(envelope.keyID),
              let signature = Data(base64Encoded: envelope.signature),
              signature.base64EncodedString() == envelope.signature else {
            throw GamePackageError.invalid("publisher signature")
        }
        let key: SecKey
        let fingerprint: String?
        let trusted: Bool
        var subject: String?
        var expiresAt: Date?
        if let encoded = envelope.certificate {
            guard let der = Data(base64Encoded: encoded), !der.isEmpty,
                  der.base64EncodedString() == encoded,
                  let certificate = SecCertificateCreateWithData(nil, der as CFData),
                  let certificateKey = SecCertificateCopyKey(certificate) else {
                throw GamePackageError.invalid("publisher certificate")
            }
            subject = SecCertificateCopySubjectSummary(certificate) as String?
            expiresAt = certificateExpiry(der)
            key = certificateKey
            let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            // Bind displayed subject/expiry to the signed message too. Merely
            // carrying a certificate with the same public key is not sufficient.
            guard envelope.keyID == digest else {
                throw GamePackageError.invalid("publisher certificate fingerprint does not match")
            }
            fingerprint = digest
            trusted = trustedCertificates.contains(digest)
        } else {
            // Original v1 packages may omit a certificate and use an already
            // provisioned P-256 public key. Never learn this pin from the package.
            guard envelope.algorithm == "ES256", let data = pinnedKeys[envelope.keyID],
                  let pinned = SecKeyCreateWithData(data as CFData,
                    [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                     kSecAttrKeyClass: kSecAttrKeyClassPublic,
                     kSecAttrKeySizeInBits: 256] as CFDictionary, nil) else {
                throw GamePackageError.invalid("publisher certificate or known public key required")
            }
            key = pinned; fingerprint = nil; trusted = true
        }
        var message = Data(("NXB-PACKAGE-SIGNATURE-V1\n" + envelope.keyID + "\n").utf8)
        message.append(manifest)
        let valid: Bool
        switch envelope.algorithm {
        case "ES256":
            // The original NXB v1 envelope uses WebCrypto's raw r || s form.
            guard signature.count == 64,
                  let data = SecKeyCopyExternalRepresentation(key, nil) as Data?,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: data),
                  let value = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
                throw GamePackageError.invalid("publisher key must be P-256")
            }
            valid = publicKey.isValidSignature(value, for: message)
        case "RS256":
            let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
            valid = SecKeyGetBlockSize(key) >= 256
                && SecKeyIsAlgorithmSupported(key, .verify, algorithm)
                && SecKeyVerifySignature(key, algorithm, message as CFData, signature as CFData, nil)
        default:
            throw GamePackageError.invalid("unsupported publisher signature algorithm")
        }
        guard valid else { throw GamePackageError.invalid("publisher signature does not match") }
        return GamePackagePublisher(keyID: envelope.keyID, certificateSHA256: fingerprint,
                                    trusted: trusted, subject: subject, expiresAt: expiresAt)
    }

    // X.509 validity is display metadata, not an acceptance policy. Security
    // validates the certificate/key; this bounded DER walk reads only notAfter.
    private static func certificateExpiry(_ data: Data) -> Date? {
        let bytes = [UInt8](data)
        func element(_ cursor: inout Int, end: Int) -> (tag: UInt8, body: Range<Int>)? {
            guard cursor + 2 <= end else { return nil }
            let tag = bytes[cursor]; cursor += 1
            var length = Int(bytes[cursor]); cursor += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...4).contains(count), cursor + count <= end else { return nil }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[cursor]); cursor += 1 }
            }
            guard length <= end - cursor else { return nil }
            let body = cursor..<cursor + length; cursor += length
            return (tag, body)
        }
        var cursor = 0
        guard let certificate = element(&cursor, end: bytes.count), certificate.tag == 0x30 else { return nil }
        cursor = certificate.body.lowerBound
        guard let tbs = element(&cursor, end: certificate.body.upperBound), tbs.tag == 0x30 else { return nil }
        cursor = tbs.body.lowerBound
        guard cursor < tbs.body.upperBound else { return nil }
        if bytes[cursor] == 0xa0 { guard element(&cursor, end: tbs.body.upperBound) != nil else { return nil } }
        for _ in 0..<3 { guard element(&cursor, end: tbs.body.upperBound) != nil else { return nil } }
        guard let validity = element(&cursor, end: tbs.body.upperBound), validity.tag == 0x30 else { return nil }
        cursor = validity.body.lowerBound
        guard element(&cursor, end: validity.body.upperBound) != nil,
              let expiry = element(&cursor, end: validity.body.upperBound),
              let text = String(bytes: bytes[expiry.body], encoding: .ascii) else { return nil }
        var normalized = text
        if expiry.tag == 0x17 {
            guard text.count == 13, let year = Int(text.prefix(2)) else { return nil }
            normalized = (year >= 50 ? "19" : "20") + text
        } else if expiry.tag != 0x18 { return nil }
        guard normalized.count == 15, normalized.last == "Z" else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        formatter.isLenient = false
        return formatter.date(from: normalized)
    }

    static func validKeyID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 46 || $0 == 95 || $0 == 45
        }
    }
}
