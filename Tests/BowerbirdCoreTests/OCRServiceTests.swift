import AppKit
import XCTest
@testable import BowerbirdCore

final class OCRServiceTests: XCTestCase {
    private func renderText(_ text: String) -> CGImage {
        let size = NSSize(width: 800, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: [
                .font: NSFont.systemFont(ofSize: 64, weight: .medium),
                .foregroundColor: NSColor.black,
            ])
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    private func renderLines(_ lines: [String]) -> CGImage {
        let image = NSImage(size: NSSize(width: 1000, height: 100 * lines.count + 40), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 40, y: 20 + 100 * index), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 48),
                    .foregroundColor: NSColor.black,
                ])
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testRecognizesEnglishAndDigits() throws {
        let text = try OCRService.recognizeText(in: renderText("Bowerbird 2026"))
        XCTAssertTrue(text.contains("Bowerbird"), "got: \(text)")
        XCTAssertTrue(text.contains("2026"), "got: \(text)")
    }

    func testRecognizesChinese() throws {
        let text = try OCRService.recognizeText(in: renderText("剪贴板历史"))
        XCTAssertTrue(text.contains("剪贴板"), "got: \(text)")
    }

    /// Chinese and an email address in one image: each must be read in its own script
    func testMixedChineseAndLatinAreBothRead() throws {
        let image = renderLines(["剪贴板历史记录", "panqian.pq@example.com"])
        let text = try OCRService.recognizeText(in: image)
        XCTAssertTrue(text.contains("剪贴板历史"), "got: \(text)")
        XCTAssertTrue(text.contains("panqian.pq@example.com"), "got: \(text)")
    }

    func testBlankImageGivesEmptyString() throws {
        let text = try OCRService.recognizeText(in: renderText(""))
        XCTAssertEqual(text, "")
    }
}
