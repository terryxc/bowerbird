import AppKit
import BowerbirdCore
import Combine
import XCTest
@testable import Bowerbird

/// The panel's "use an item" path.
///
/// This layer had no tests at all, yet both bugs caught yesterday were here: keyboard and mouse
/// each had their own entry point and the missing-permission handling was added to only one of them;
/// and the two gates on the resumed paste had only been checked on a real machine with a stopwatch.
/// Clicking through by hand only proves it isn't broken right now.
@MainActor
final class PanelModelTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!
    private var permission: FakePermission!
    /// The resumed paste needs a target app that is still alive. The test process won't do: it isn't
    /// a launched app, and `NSRunningApplication.current.isTerminated` is true in practice. Finder is always running.
    private var liveApp: NSRunningApplication!
    /// Fake clipboard generation. Reading the real NSPasteboard.general would drag in the clipboard of whoever runs the tests.
    private var clipboardGeneration = 1

    // XCTest's synchronous setUp and tearDown are nonisolated on Xcode 16, so the async variants hop
    // onto the main actor explicitly; this compiles on both toolchains
    override func setUp() async throws {
        try await MainActor.run {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bowerbird-panel-tests-\(UUID().uuidString)", isDirectory: true)
            store = try HistoryStore(databaseURL: nil,
                                     imagesDirectory: root.appendingPathComponent("images", isDirectory: true))
            permission = FakePermission()
            liveApp = try XCTUnwrap(
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        }
    }

    override func tearDown() async throws {
        await MainActor.run { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Setup

    private func makeModel(trusted: Bool) -> PanelModel {
        permission.isTrusted = trusted
        let model = PanelModel(store: store, permission: permission,
                               changeCount: { [unowned self] in self.clipboardGeneration })
        model.items = [item(id: 1, "第一条"), item(id: 2, "第二条")]
        model.selectedIndex = 0
        return model
    }

    private func item(id: Int64, _ text: String) -> ClipItem {
        ClipItem(id: id, kind: .text, content: text, contentHash: "hash-\(id)",
                 sourceBundleID: nil, createdAt: Date(), byteSize: text.utf8.count,
                 title: text)
    }

    /// Records onActivate / onDismiss calls so tests can assert which path was taken
    private struct Activation {
        var items: [(id: Int64?, copyOnly: Bool, variant: ClipVariant)] = []
        var dismissals = 0
        var resumes = 0
    }

    private func wire(_ model: PanelModel, into log: Log) {
        model.onActivate = { item, copyOnly, variant in
            log.value.items.append((item.id, copyOnly, variant))
        }
        model.onDismiss = { log.value.dismissals += 1 }
        model.onResumePaste = { _ in log.value.resumes += 1 }
        // The real ⌘V is sent by whoever handles onResumePaste; here we only count the calls, nothing is actually pasted
        model.pasteTarget = liveApp
    }

    private final class Log {
        var value = Activation()
    }

    // MARK: Normal path with permission

    func testReturnPastesAndClosesThePanel() {
        let model = makeModel(trusted: true)
        let log = Log()
        wire(model, into: log)

        model.perform(.paste)

        XCTAssertEqual(log.value.items.count, 1)
        XCTAssertEqual(log.value.items.first?.id, 1)
        XCTAssertEqual(log.value.items.first?.copyOnly, false)
        XCTAssertEqual(log.value.dismissals, 1, "The panel should close after pasting")
        XCTAssertFalse(model.showsPermissionCard)
    }

    func testCopyClosesThePanelWithoutPasting() {
        let model = makeModel(trusted: true)
        let log = Log()
        wire(model, into: log)

        model.perform(.copy)

        XCTAssertEqual(log.value.items.first?.copyOnly, true)
        XCTAssertEqual(log.value.dismissals, 1)
    }

    /// Keyboard and mouse must take the same entry point.
    ///
    /// This is exactly that bug: Return went through activateSelected and clicks through
    /// activate(id:), two entry points doing the same thing, so the missing-permission handling
    /// was added to only one of them.
    func testKeyboardAndMouseTakeTheSameRoute() {
        let byKeyboard = makeModel(trusted: false)
        let keyboardLog = Log()
        wire(byKeyboard, into: keyboardLog)
        byKeyboard.perform(.paste)

        let byMouse = makeModel(trusted: false)
        let mouseLog = Log()
        wire(byMouse, into: mouseLog)
        byMouse.activate(id: 1, copyOnly: false)

        XCTAssertEqual(keyboardLog.value.items.map(\.copyOnly), mouseLog.value.items.map(\.copyOnly))
        XCTAssertEqual(keyboardLog.value.dismissals, mouseLog.value.dismissals)
        XCTAssertEqual(byKeyboard.showsPermissionCard, byMouse.showsPermissionCard)
    }

    // MARK: Without permission

    func testWithoutPermissionItCopiesAndExplainsInsteadOfFailingSilently() {
        let model = makeModel(trusted: false)
        let log = Log()
        wire(model, into: log)

        model.perform(.paste)

        XCTAssertEqual(log.value.items.count, 1)
        XCTAssertEqual(log.value.items.first?.copyOnly, true,
                       "Copy even when pasting is impossible; this content is what Return was pressed for")
        XCTAssertEqual(log.value.dismissals, 0, "The panel must stay open so the card can explain")
        XCTAssertTrue(model.showsPermissionCard)
    }

    func testCopyStillWorksWithoutPermission() {
        let model = makeModel(trusted: false)
        let log = Log()
        wire(model, into: log)

        model.perform(.copy)

        XCTAssertEqual(log.value.items.first?.copyOnly, true)
        XCTAssertEqual(log.value.dismissals, 1, "Copying alone needs no permission, so the panel closes as usual")
        XCTAssertFalse(model.showsPermissionCard, "No paste was intended, so it should not ask for permission")
    }

    /// Return while the card is showing presses its primary button instead of triggering "can't paste" again
    func testReturnOnTheCardAsksForThePermission() {
        let model = makeModel(trusted: false)
        let log = Log()
        wire(model, into: log)
        model.perform(.paste)
        let afterFirst = log.value.items.count

        model.perform(.paste)

        XCTAssertEqual(permission.requests, 1)
        XCTAssertEqual(log.value.items.count, afterFirst, "Should not copy again")
        XCTAssertEqual(log.value.dismissals, 1, "Close the panel before going to System Settings, otherwise it covers the system dialog")
    }

    func testNotNowClearsThePendingPaste() {
        let model = makeModel(trusted: false)
        let log = Log()
        wire(model, into: log)
        model.perform(.paste)

        model.dismissPermissionCard()
        XCTAssertFalse(model.showsPermissionCard)
        XCTAssertEqual(log.value.dismissals, 1, "The content is already on the clipboard, so the panel should close")

        // Granting permission later must not paste anything into any window out of nowhere
        permission.grant()
        XCTAssertEqual(log.value.resumes, 0)
    }

    // MARK: The two gates on the resumed paste

    func testPendingSurvivesAnUnchangedClipboardWithinTheWindow() {
        let pending = PanelModel.PendingPaste(changeCount: 7,
                                              expires: Date().addingTimeInterval(300))
        XCTAssertTrue(pending.stillWanted(now: Date(), changeCount: 7))
    }

    func testPendingIsDroppedOnceTheClipboardMovedOn() {
        let pending = PanelModel.PendingPaste(changeCount: 7,
                                              expires: Date().addingTimeInterval(300))
        XCTAssertFalse(pending.stillWanted(now: Date(), changeCount: 8),
                       "Something else was copied since; the old item must not replace it")
    }

    func testPendingExpires() {
        let expiry = Date()
        let pending = PanelModel.PendingPaste(changeCount: 7, expires: expiry)
        XCTAssertFalse(pending.stillWanted(now: expiry.addingTimeInterval(1), changeCount: 7))
        XCTAssertTrue(pending.stillWanted(now: expiry.addingTimeInterval(-1), changeCount: 7))
    }

    func testGrantingResumesThePasteTheUserAskedFor() {
        let model = makeModel(trusted: false)
        let log = Log()
        wire(model, into: log)
        model.perform(.paste)

        permission.grant()

        XCTAssertEqual(log.value.resumes, 1, "This is the paste that was being waited for")
        XCTAssertFalse(model.showsPermissionCard)
    }

    func testGrantingDoesNotResumeAfterTheClipboardMovedOn() {
        let model = makeModel(trusted: false)
        let log = Log()
        wire(model, into: log)
        model.perform(.paste)
        clipboardGeneration += 1   // something else was copied

        permission.grant()

        XCTAssertEqual(log.value.resumes, 0, "Old content must not replace what was just copied")
    }

    func testGrantingWithNothingPendingPastesNothing() {
        let model = makeModel(trusted: false)
        let log = Log()
        wire(model, into: log)

        permission.grant()

        XCTAssertEqual(log.value.resumes, 0)
        XCTAssertEqual(log.value.items.count, 0)
        XCTAssertEqual(log.value.dismissals, 0)
    }

    // MARK: Address by id, not by index

    /// The list keeps refreshing while a context menu is open (new content arrives, OCR finishes).
    /// Addressed by index, choosing "Delete" in the menu could delete another item that shifted into place.
    func testActionsAddressTheItemTheyWereGivenEvenAfterTheListShifts() {
        let model = makeModel(trusted: true)
        let log = Log()
        wire(model, into: log)

        // The menu was opened on the second item; meanwhile new content was inserted at the top
        model.items = [item(id: 3, "插进来的"), item(id: 1, "第一条"), item(id: 2, "第二条")]

        model.activate(id: 2, copyOnly: false)

        XCTAssertEqual(log.value.items.first?.id, 2, "Use the item that was clicked, not whatever is at that row")
    }

    func testSelectingAnItemThatIsNoLongerThereChangesNothing() {
        let model = makeModel(trusted: true)
        model.select(id: 99)
        XCTAssertEqual(model.selectedID, 1)
    }

    /// Typing a search makes a new, ranked list; the selection must go to its first row, not stay on
    /// whatever row number it was on in the old list. Observed: arrow down to row 3, type "duty", and
    /// the selection sat on the third result instead of the first.
    func testAChangedSearchSelectsTheFirstResult() throws {
        for text in ["off duty roster", "duty free", "duty call", "nothing here", "也无关"] {
            _ = try store.record(ClipCapture(assets: [.init(type: .string, data: Data(text.utf8))],
                                             kind: .text, text: text), sourceBundleID: nil)
        }
        let model = makeModel(trusted: true)
        model.reload()
        wait(until: { model.items.count == 5 })
        model.selectedIndex = 2

        model.query = "duty"
        wait(until: { model.items.count == 3 })

        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.selected?.content, "duty call", "newest match first")
    }

    /// A refresh that is not a search keeps the row the user is on
    func testAPlainRefreshKeepsTheSelection() throws {
        for text in ["one", "two", "three"] {
            _ = try store.record(ClipCapture(assets: [.init(type: .string, data: Data(text.utf8))],
                                             kind: .text, text: text), sourceBundleID: nil)
        }
        let model = makeModel(trusted: true)
        model.reload()
        wait(until: { model.items.count == 3 })
        model.selectedIndex = 2

        model.reload()
        wait(until: { model.loaded })
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(model.selectedIndex, 2)
    }

    /// Choosing a kind in the search row's menu narrows the list; "All" brings everything back
    func testKindFilterNarrowsTheList() throws {
        _ = try store.record(ClipCapture(assets: [.init(type: .string, data: Data("words".utf8))],
                                         kind: .text, text: "words"), sourceBundleID: nil)
        _ = try store.record(ClipCapture(assets: [.init(type: .png, data: Data([0x89, 0x50, 0x4E, 0x47, 9]))],
                                         kind: .image, text: "", imageSize: CGSize(width: 8, height: 8)), sourceBundleID: nil)
        let model = makeModel(trusted: true)
        model.reload()
        wait(until: { model.items.count == 2 })

        model.kindFilter = .text
        wait(until: { model.items.count == 1 })
        XCTAssertEqual(model.items.first?.kind, .text)
        XCTAssertEqual(model.kindFilterLabel, L("Text"))

        model.kindFilter = nil
        wait(until: { model.items.count == 2 })
        XCTAssertEqual(model.kindFilterLabel, L("All"))
    }

    /// Home, End, Page Up and Page Down; a page is the number of rows the list shows
    func testJumpingToTheEndsAndByPages() {
        let model = makeModel(trusted: true)
        model.items = (1...30).map { item(id: Int64($0), "row \($0)") }
        model.selectedIndex = 0

        model.moveSelectionToEnd(.last)
        XCTAssertEqual(model.selectedIndex, 29)
        model.moveSelectionToEnd(.first)
        XCTAssertEqual(model.selectedIndex, 0)

        let page = AppSettings.shared.panelSize.visibleRows
        XCTAssertGreaterThan(page, 1)
        model.moveSelection(pages: 1)
        XCTAssertEqual(model.selectedIndex, min(page, 29))
        model.moveSelection(pages: -1)
        XCTAssertEqual(model.selectedIndex, 0, "clamped at the top")
        model.moveSelection(pages: 5)
        XCTAssertEqual(model.selectedIndex, 29, "clamped at the bottom")
    }

    private func wait(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !done(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// The format belongs to the **selected** item. Other rows use the first chip; pasting another
    /// row with this row's format choice would be wrong.
    func testAnotherRowIsPastedAsCapturedNotWithTheSelectedRowsFormat() {
        let model = makeModel(trusted: true)
        let log = Log()
        wire(model, into: log)
        model.variant = .plainText

        model.activate(id: 2, copyOnly: false)

        XCTAssertEqual(log.value.items.first?.variant, .asCaptured)
    }
}

/// A permission object the test controls. Asking the real system would depend on whether the machine running the tests has granted it.
@MainActor
private final class FakePermission: AccessibilityState {
    @Published var isTrusted = false
    private(set) var requests = 0

    var isTrustedChanged: AnyPublisher<Bool, Never> { $isTrusted.eraseToAnyPublisher() }
    func request() { requests += 1 }
    func refresh() {}

    /// Simulates turning the switch on in System Settings
    func grant() { isTrusted = true }
}
