import XCTest
@testable import Bowerbird

final class SingleInstanceTests: XCTestCase {
    /// Only ourselves in the registry: a normal first launch, allowed.
    func testNoPeerWhenOnlySelfIsRunning() {
        let peer = SingleInstance.peer(among: [.init(processIdentifier: 42)], selfPID: 42)
        XCTAssertNil(peer)
    }

    func testEmptyCandidatesAllowLaunch() {
        XCTAssertNil(SingleInstance.peer(among: [], selfPID: 42))
    }

    /// The copy in the DMG is running first, then the user launches again from /Applications: two
    /// pids, the same bundle id.
    func testDetectsAnotherRunningCopy() {
        let peer = SingleInstance.peer(
            among: [.init(processIdentifier: 7), .init(processIdentifier: 42)], selfPID: 42)
        XCTAssertEqual(peer?.processIdentifier, 7)
    }

    /// An instance that just quit lingers in Launch Services' registry for a while.
    /// Treating it as "one is already running" would make the app fail to open after quitting and
    /// relaunching.
    func testIgnoresTerminatedCopies() {
        let peer = SingleInstance.peer(
            among: [.init(processIdentifier: 7, isTerminated: true),
                    .init(processIdentifier: 42)],
            selfPID: 42)
        XCTAssertNil(peer)
    }

    func testPicksLiveCopyOverTerminatedOne() {
        let peer = SingleInstance.peer(
            among: [.init(processIdentifier: 7, isTerminated: true),
                    .init(processIdentifier: 9),
                    .init(processIdentifier: 42)],
            selfPID: 42)
        XCTAssertEqual(peer?.processIdentifier, 9)
    }
}
