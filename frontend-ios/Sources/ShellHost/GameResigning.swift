import Foundation
import Darwin
import Observation

/// All windows share the same process and loaded images.
@MainActor @Observable final class GameSigningSession {
    static let shared = GameSigningSession()
    var resigning = false

    private struct Window {
        weak var model: ShellHostModel?
    }
    private var windows: [Window] = []

    func register(_ model: ShellHostModel) {
        windows.removeAll { $0.model == nil }
        windows.append(Window(model: model))
    }

    func reload() {
        for window in windows { window.model?.reload() }
    }

    /// Native gameplay, preparation and cloud decisions reserve every window.
    /// Weak references release the reservation when a window/model goes away.
    var hasPendingLaunch: Bool {
        windows.contains { window in
            guard let model = window.model else { return false }
            return model.launchingGame || model.isGameRunning || model.cloudConflict != nil
        }
    }
}

/// Captured from a regular file, never reconstructed from caller-supplied timestamps.
public struct GameSigningFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64

    init(file: URL) throws {
        var value = stat()
        guard lstat(file.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_size >= 0 else {
            throw ShellSigningError.invalid("installed executable changed while signing")
        }
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
        size = value.st_size
        modificationSeconds = Int64(value.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changeSeconds = Int64(value.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

/// Created only after verified signature-only signing and a successful atomic exchange.
public struct GameResigningReceipt: Sendable {
    public let titleID: String
    public let executable: URL
    public let previousModificationSeconds: Int64
    public let installedFile: GameSigningFileIdentity
}


/// Work only on a private sibling stage. Existing game bytes survive every signing failure.
enum GameResigning {
    static func isEligible(framework: URL, hotRoot: URL, titleID: String) -> Bool {
        framework.isFileURL && hotRoot.isFileURL && isTitleID(titleID.uppercased()) &&
            framework.pathExtension == "framework" &&
            framework.deletingLastPathComponent().standardizedFileURL == hotRoot.standardizedFileURL &&
            framework.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == hotRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    @discardableResult static func replace(framework: URL, hotRoot: URL, titleID: String,
                      sign: (URL) throws -> Void) throws -> GameResigningReceipt {
        let fm = FileManager.default
        guard isEligible(framework: framework, hotRoot: hotRoot, titleID: titleID) else {
            throw ShellSigningError.invalid("only imported games can be re-signed")
        }
        // The catalogue supports imported frameworks with their own basenames.
        let expected = framework.lastPathComponent
        let originalIdentity = try directoryIdentity(framework)
        // Validate before copying too, so symlinks cannot pull other files into the stage.
        let files = try ShellFrameworkResigner.nativeFiles(framework: framework)
        guard files.count == 1, let executable = files.first else {
            throw ShellSigningError.invalid("only single-image frameworks can be re-signed")
        }
        let originalFile = try GameSigningFileIdentity(file: executable)
        // Only exact directories owned by this workflow. A previous interruption
        // cannot leave the installed path missing, so these copies are expendable.
        for old in try fm.contentsOfDirectory(at: hotRoot, includingPropertiesForKeys: nil) {
            let name = old.lastPathComponent
            guard name.hasPrefix(".resigning-") else { continue }
            let tail = String(name.dropFirst(".resigning-".count))
            guard tail.count == 53, tail.dropFirst(16).first == "-",
                  isTitleID(String(tail.prefix(16))), UUID(uuidString: String(tail.dropFirst(17))) != nil else { continue }
            try fm.removeItem(at: old)
        }
        let stage = hotRoot.appendingPathComponent(".resigning-" + titleID + "-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        var protectedStage = stage
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedStage.setResourceValues(values)
        let copy = stage.appendingPathComponent(expected)
        try fm.copyItem(at: framework, to: copy)
        try sign(copy)
        let signedExecutable = copy.appendingPathComponent(executable.lastPathComponent)
        let signedFile = try GameSigningFileIdentity(file: signedExecutable)
        try verifySignatureOnlyChange(original: executable, signed: signedExecutable)
        // Detect an external importer replacing the source while signing. This
        // is not a lock against external writers or in-place file mutations.
        guard try directoryIdentity(framework) == originalIdentity,
              try GameSigningFileIdentity(file: executable) == originalFile,
              try GameSigningFileIdentity(file: signedExecutable) == signedFile else {
            throw ShellSigningError.invalid("installed game changed while signing")
        }
        // The kernel has accepted every image. Atomic exchange is the commit
        // point: interruption leaves either the old or the complete signed copy.
        guard renameatx_np(AT_FDCWD, framework.path, AT_FDCWD, copy.path, UInt32(RENAME_SWAP)) == 0 else {
            throw ShellSigningError.invalid("cannot atomically install the signed game")
        }
        // The original now lives in stage and is removed by defer. A crash may
        // leave this hidden backup, but never an absent installed framework.
        return GameResigningReceipt(titleID: titleID, executable: executable,
                                    previousModificationSeconds: originalFile.modificationSeconds,
                                    installedFile: signedFile)
    }

    /// The signed image must have the same headers, code and data. Only its
    /// existing signature reservation may differ; no timestamp is rewritten.
    static func verifySignatureOnlyChange(original: URL, signed: URL) throws {
        let before = try FileHandle(forReadingFrom: original)
        defer { try? before.close() }
        let after = try FileHandle(forReadingFrom: signed)
        defer { try? after.close() }
        let size = try before.seekToEnd()
        guard try after.seekToEnd() == size,
              let signature = FrameworkSignature.inspect(executable: signed), signature.hasCodeSignature,
              signature.sliceOffset == 0, signature.signatureOffset >= 48, signature.signatureSize > 0 else {
            throw ShellSigningError.invalid("signing changed the native image layout")
        }
        let start = UInt64(signature.signatureOffset)
        let end = start + UInt64(signature.signatureSize)
        guard end <= size else { throw ShellSigningError.invalid("invalid signature reservation") }
        // Comparing the header also proves that LC_CODE_SIGNATURE's offset and
        // size did not move, even when the original reservation was unsigned.
        for range in [UInt64(0)..<start, end..<size] {
            try before.seek(toOffset: range.lowerBound)
            try after.seek(toOffset: range.lowerBound)
            var remaining = range.count
            while remaining > 0 {
                let count = min(remaining, 1024 * 1024)
                let a = try before.read(upToCount: count) ?? Data()
                let b = try after.read(upToCount: count) ?? Data()
                guard a.count == count, b.count == count, a == b else {
                    throw ShellSigningError.invalid("signing changed bytes outside the signature")
                }
                remaining -= count
            }
        }
    }

    private static func directoryIdentity(_ url: URL) throws -> [UInt64] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw ShellSigningError.invalid("installed framework directory changed")
        }
        return [device.uint64Value, inode.uint64Value]
    }

}
