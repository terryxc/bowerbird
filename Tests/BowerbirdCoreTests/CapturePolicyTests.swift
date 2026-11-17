import AppKit
import XCTest
@testable import BowerbirdCore

/// The switches on the History page: a kind that is switched off is not recorded.
final class CapturePolicyTests: XCTestCase {
    private let text = ClipCapture(assets: [.init(type: .string, data: Data("hello".utf8))], kind: .text, text: "hello")
    private let image = ClipCapture(assets: [.init(type: .png, data: Data([0x89, 0x50]))], kind: .image, text: "",
                                    imageSize: CGSize(width: 4, height: 4))
    private let file = ClipCapture(assets: [], kind: .file, text: "", filePaths: ["/tmp/secret/a.txt"])

    func testAKindThatIsSwitchedOffIsNotRecorded() {
        let policy = CapturePolicy(kinds: [.text, .file], acceptsRemote: true, ignorePatterns: IgnorePatterns([]))
        XCTAssertTrue(policy.allows(text))
        XCTAssertTrue(policy.allows(file))
        XCTAssertFalse(policy.allows(image), "Images is unchecked")
    }

    func testNothingIsRecordedWithEveryKindOff() {
        let policy = CapturePolicy(kinds: [], acceptsRemote: true, ignorePatterns: IgnorePatterns([]))
        XCTAssertFalse(policy.allows(text))
        XCTAssertFalse(policy.allows(image))
        XCTAssertFalse(policy.allows(file))
    }

    /// Files are matched on their paths, everything else on the text
    func testIgnoreRulesLookAtAFilesPath() {
        let policy = CapturePolicy(kinds: [.text, .image, .file], acceptsRemote: true,
                                   ignorePatterns: IgnorePatterns(["secret"]))
        XCTAssertFalse(policy.allows(file))
        XCTAssertTrue(policy.allows(text))
    }
}
