import XCTest
@testable import ShellHost

final class GameBuildReportTests: XCTestCase {
    func testKnownShaderFailureIncludesStageCountsAndVersions() {
        var report = GameBuildReport()
        report.record(GameBuildProgress(nativeStage: "shaders.compile:20:40"))
        let native = NativeGameBuildFailure(
            diagnostic: #"shader 0546f10865524d24_b compilation: "front end rejected: unsupported:rejected:addrspace-value:thread""#
        )
        let revision = String(repeating: "a", count: 40)
        let text = report.text(failure: .buildFailed, native: native, info: [
            "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42",
            "NXKitRuntimeRevision": revision, "NXKitRuntimeABI": 1
        ])
        for value in ["App version: 1.2.3", "App build: 42", "Runtime revision: \(revision)", "Runtime ABI: 1",
                      "shaders.compile 20/40", "Shader: 0546f10865524d24_b", "Reason: addrspace-value:thread"] {
            XCTAssertTrue(text.contains(value), text)
        }
    }

    func testUntrustedTextNeverAppearsAndReportLengthIsBounded() {
        var report = GameBuildReport()
        let privateText = "/Users/test/prod.keys https://example.com game-source password"
        for done in 1...100 {
            report.record(GameBuildProgress(stage: "inputs", message: privateText, completedFiles: done, totalFiles: 100))
        }
        let native = NativeGameBuildFailure(diagnostic: "shader 0546f10865524d24_b compilation: \(privateText)")
        let text = report.text(failure: .buildFailed, native: native, info: [
            "CFBundleShortVersionString": privateText, "CFBundleVersion": "1\nprivate build",
            "NXKitRuntimeRevision": privateText
        ])
        for secret in ["/Users", "prod.keys", "https:", "game-source", "password", "private build", "Reason:"] {
            XCTAssertFalse(text.contains(secret), text)
        }
        XCTAssertTrue(text.contains("Shader: 0546f10865524d24_b"))
        XCTAssertFalse(text.contains("inputs 76/100"))
        XCTAssertTrue(text.contains("inputs 77/100"))
        XCTAssertTrue(text.hasSuffix("inputs 100/100"))
    }
}
