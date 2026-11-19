import Foundation

/// Actual import work boundaries, not estimated percentages.
public enum PackageImportStage: String, Sendable {
    case readingAndVerifying
    case signing
    case installing
}

public enum PackageCommandLineImportError: String, LocalizedError, Sendable {
    case busy = "The library is busy."
    case input = "The package could not be read or verified."
    case untrusted = "Publisher is unsigned or untrusted. Use --allow-untrusted only if you trust this package."
    case signingIdentity = "A matching signing identity is required. Import it first and unlock Keychain."
    case compatibility = "This package is not compatible with this runtime or operating system."
    case alreadyInstalled = "This game is already installed."
    case installation = "Import failed. Existing installed game was not replaced. Check the signing identity."
    public var errorDescription: String? { rawValue }
}
