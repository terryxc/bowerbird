import AppKit
import BowerbirdCore
import Combine
import XCTest
@testable import Bowerbird

/// The format bar: which options, which one is selected, and when to reset.
///
/// Picking the wrong format isn't a display issue; it decides what gets pasted. There was once a bug
/// where every reload reset the format: an image finished OCR, the list refreshed, the "Plain Text"
/// just chosen snapped back to "Formatted", Return still pasted formatted content, and nothing on
/// screen looked wrong.
@MainActor
final class FormatBarTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!

    // XCTest's synchronous setUp and tearDown are nonisolated on Xcode 16, so the async variants hop
    // onto the main actor explicitly; this compiles on both toolchains
    override func setUp() async throws {
        try await MainActor.run {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bowerbird-format-tests-\(UUID().uuidString)", isDirectory: true)
            store = try HistoryStore(databaseURL: nil,
                                     imagesDirectory: root.appendingPathComponent("images", isDirectory: true))
        }
    }

    override func tearDown() async throws {
        await MainActor.run { try? FileManager.default.removeItem(at: root) }
    }

    private func makeModel() -> PanelModel {
        PanelModel(store: store, permission: InertPermission(), changeCount: { 1 })
    }

    /// Really record it so assetSummaries finds something; the format bar is computed from it
    @discardableResult
    private func record(_ capture: ClipCapture) throws -> ClipItem {
        try store.record(capture, sourceBundleID: nil)
    }

    private func richText(_ text: String) -> ClipCapture {
        ClipCapture(assets: [.init(type: .rtf, data: Data("{\\rtf1 \(text)}".utf8)),
                             .init(type: .string, data: Data(text.utf8))],
                    kind: .text, text: text)
    }

    private func plainText(_ text: String) -> ClipCapture {
        ClipCapture(assets: [.init(type: .string, data: Data(text.utf8))], kind: .text, text: text)
    }

    private func image(_ png: Data = Data([0x89, 0x50, 0x4E, 0x47])) -> ClipCapture {
        ClipCapture(assets: [.init(type: .png, data: png)], kind: .image, text: "",
                    imageSize: CGSize(width: 8, height: 8))
    }

    /// Waits for the model to fetch and select the clip
    private func load(_ model: PanelModel, expecting count: Int) {
        model.reload()
        let deadline = Date().addingTimeInterval(2)
        while model.items.count < count, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: Recognizing

    /// A freshly copied screenshot: before text is recognized, the format bar must already be shown
    /// with a "Recognizing…" slot.
    ///
    /// Otherwise the "Text in Image" option pops up out of nowhere a few seconds later, and during
    /// those seconds nobody knows what the app is doing or whether to wait.
    func testAFreshScreenshotSaysItIsStillReading() throws {
        let original = AppSettings.shared.recognizeText
        defer { AppSettings.shared.recognizeText = original }
        AppSettings.shared.recognizeText = true

        try record(image())
        let model = makeModel()
        load(model, expecting: 1)

        XCTAssertTrue(model.isRecognizing)
        XCTAssertEqual(model.variants, [.asCaptured], "no second option to pick yet")
        XCTAssertTrue(model.showsFormatBar, "but the bar must hold its place first so the layout doesn't jump")
    }

    /// Recognition finished and the image really has no text: it shouldn't keep spinning
    func testAnImageWithNoWordsStopsSayingItIsReading() throws {
        let original = AppSettings.shared.recognizeText
        defer { AppSettings.shared.recognizeText = original }
        AppSettings.shared.recognizeText = true

        let item = try record(image())
        try store.setOCRText(id: try XCTUnwrap(item.id), "")
        let model = makeModel()
        load(model, expecting: 1)

        XCTAssertFalse(model.isRecognizing, "an empty string means \"recognized, no text\", not \"not recognized yet\"")
        XCTAssertFalse(model.showsFormatBar)
    }

    /// Once text is recognized, the placeholder must turn into the real "Text in Image" option
    func testRecognisedWordsBecomeARealChoice() throws {
        let original = AppSettings.shared.recognizeText
        defer { AppSettings.shared.recognizeText = original }
        AppSettings.shared.recognizeText = true

        let item = try record(image())
        try store.setOCRText(id: try XCTUnwrap(item.id), "ZEBRAFISH 2026")
        let model = makeModel()
        load(model, expecting: 1)

        XCTAssertFalse(model.isRecognizing, "once recognition is done it shouldn't say it is still recognizing")
        XCTAssertEqual(model.variants, [.asCaptured, .recognizedText])
        XCTAssertTrue(model.showsFormatBar)
    }

    /// With recognition switched off, it shouldn't still claim to be recognizing
    func testNothingIsReadingWhenTheFeatureIsOff() throws {
        let original = AppSettings.shared.recognizeText
        defer { AppSettings.shared.recognizeText = original }
        AppSettings.shared.recognizeText = false

        try record(image())
        let model = makeModel()
        load(model, expecting: 1)

        XCTAssertFalse(model.isRecognizing)
        XCTAssertFalse(model.showsFormatBar)
    }

    /// Text clips are never "recognizing"
    func testTextIsNeverReading() throws {
        try record(plainText("一段字"))
        let model = makeModel()
        load(model, expecting: 1)
        XCTAssertFalse(model.isRecognizing)
    }

    func testPlainTextHasNothingToChooseSoTheBarStaysHidden() throws {
        let item = try record(plainText("就一段字"))
        let model = makeModel()
        model.items = [item]
        model.selectedIndex = 0

        XCTAssertEqual(model.variants, [.asCaptured])
        XCTAssertFalse(model.showsFormatBar, "with only one option it shouldn't take up those 32 points")
    }

    /// Plain text for a rich clip is a key (⇧⌘↩), not a cell: the preview would look the same in both
    func testRichTextShowsNoFormatBar() throws {
        let item = try record(richText("带格式的"))
        let model = makeModel()
        model.items = [item]
        model.selectedIndex = 0

        XCTAssertEqual(model.variants, [.asCaptured])
        XCTAssertFalse(model.showsFormatBar)
    }

    func testAFileOffersItsPathWithoutTouchingTheDatabase() {
        let model = makeModel()
        model.items = [fileItem(path: "/tmp/a.txt")]
        model.selectedIndex = 0

        XCTAssertEqual(model.variants, [.asCaptured, .path])
    }

    func testSwitchingItemsResetsToTheFirstFormat() throws {
        let model = makeModel()
        model.items = [fileItem(path: "/tmp/a.txt", id: 1), fileItem(path: "/tmp/b.txt", id: 2)]
        model.selectedIndex = 0
        model.variant = .path

        model.selectedIndex = 1

        XCTAssertEqual(model.variant, .asCaptured, "the format is a temporary choice tied to the clip")
    }

    /// The same clip must not lose its chosen format because the list reloaded; that would silently change
    /// what gets pasted
    func testTheChosenFormatSurvivesAReloadOfTheSameItem() throws {
        let file = fileItem(path: "/tmp/a.txt")
        let model = makeModel()
        model.items = [file]
        model.selectedIndex = 0
        model.variant = .path

        // Simulate a reload: the list is replaced by an equivalent new array, same item selected
        model.items = [file]
        model.selectedIndex = 0

        XCTAssertEqual(model.variant, .path)
    }

    /// Pinning moves the row to the top of the list. The format chosen for it must come along:
    /// it used to snap back to the first one, and Return pasted the file instead of its path.
    func testPinningKeepsTheChosenFormat() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: url)
        let file = try record(ClipCapture(assets: [.init(type: .fileURL, data: url.dataRepresentation)],
                                          kind: .file, text: "", filePaths: [url.path]))
        try record(plainText("copied after the file"))
        let model = makeModel()
        load(model, expecting: 2)
        model.selectedIndex = 1
        XCTAssertEqual(model.selected?.id, file.id, "precondition: the file is the second row")
        model.variant = .path

        model.togglePinSelected()
        let deadline = Date().addingTimeInterval(2)
        while model.items.first?.pinned != true, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(model.selectedIndex, 0, "the pinned row moved to the top and is still selected")
        XCTAssertEqual(model.selected?.id, file.id)
        XCTAssertEqual(model.variant, .path)
    }

    func testCyclingWrapsAround() throws {
        let model = makeModel()
        model.items = [fileItem(path: "/tmp/a.txt")]
        model.selectedIndex = 0

        model.cycleFormat(1)
        XCTAssertEqual(model.variant, .path)
        model.cycleFormat(1)
        XCTAssertEqual(model.variant, .asCaptured, "wraps around at the end")
        model.cycleFormat(-1)
        XCTAssertEqual(model.variant, .path, "⇧⇥ goes backwards")
    }

    func testCyclingDoesNothingWhenThereIsNoChoice() throws {
        let item = try record(plainText("就一段字"))
        let model = makeModel()
        model.items = [item]
        model.selectedIndex = 0

        model.cycleFormat(1)

        XCTAssertEqual(model.variant, .asCaptured)
    }

    func testAnEmptyListHasNoFormats() {
        let model = makeModel()
        model.items = []

        XCTAssertEqual(model.variants, [.asCaptured])
        XCTAssertFalse(model.showsFormatBar)
    }

    /// A file clip's content is a JSON array of paths; filePaths is decoded from it
    private func fileItem(path: String, id: Int64 = 99) -> ClipItem {
        let content = String(data: try! JSONEncoder().encode([path]), encoding: .utf8)!
        return ClipItem(id: id, kind: .file, content: content, contentHash: "file-hash",
                        sourceBundleID: nil, createdAt: Date(), byteSize: path.utf8.count,
                        title: (path as NSString).lastPathComponent)
    }
}

/// This group of tests doesn't touch permissions, so give it one that does nothing
@MainActor
private final class InertPermission: AccessibilityState {
    @Published var isTrusted = true
    var isTrustedChanged: AnyPublisher<Bool, Never> { $isTrusted.eraseToAnyPublisher() }
    func request() {}
    func refresh() {}
}
