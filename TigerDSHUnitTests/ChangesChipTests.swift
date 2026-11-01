import XCTest
@testable import TigerDSH

/// A change chip's summary across a reconnect and a chip leaving the screen (the 10-15 "Checking changes…" chips that
/// never finished). Every read is held at a gate, so the order things land in is the test's, not the network's.
@MainActor
final class ChangesChipTests: XCTestCase {
    /// One held read: the test lets it answer when it chooses.
    private final class Gate: @unchecked Sendable {
        private var waiting: CheckedContinuation<JSON, Error>?
        private var started: CheckedContinuation<Void, Never>?
        private var count = 0
        /// Like a URLSession read, it gives up when the task asking for it is cancelled.
        func fetch() async throws -> JSON {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { c in
                    DispatchQueue.main.async { self.waiting = c; self.count += 1; self.started?.resume(); self.started = nil }
                }
            } onCancel: {
                DispatchQueue.main.async { let c = self.waiting; self.waiting = nil; c?.resume(throwing: CancellationError()) }
            }
        }
        func whenStarted() async { await withCheckedContinuation { c in DispatchQueue.main.async { if self.waiting != nil { c.resume() } else { self.started = c } } } }
        func answer(_ v: JSON) { let c = waiting; waiting = nil; c?.resume(returning: v) }
        var reads: Int { count }
    }

    private func model(_ gate: Gate) -> ChatModel {
        let m = ChatModel(id: "session-test", app: nil)
        m.fetchChanges = { _, _ in try await gate.fetch() }
        return m
    }

    func testSnapshotClearsSummariesAndRekeysTheLoad() {
        let m = ChatModel(id: "session-test", app: nil)
        m.changes[7] = ["total": 2, "added": 5, "deleted": 1]
        let before = m.snapshots
        m.resetState()
        XCTAssertNotEqual(m.snapshots, before, "a snapshot has to re-run the chip's load")
        XCTAssertTrue(m.changes.isEmpty)
    }

    /// The chip that started the read leaves the screen; the sheet showing the same "wait" still gets the answer.
    func testCancelledLoaderStillFinishesTheRead() async {
        let gate = Gate(), m = model(gate)
        let chip = Task { await m.loadChanges(4) }
        await gate.whenStarted()
        await m.loadChanges(4)                       // a second view: sees the read on its way and leaves it be
        chip.cancel()
        await Task.yield(); await Task.yield()       // let a cancel reach the read, as a real one would
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        gate.answer(["total": 1, "added": 2, "deleted": 0])
        await chip.value
        XCTAssertEqual(m.changes[4]?["total"].int, 1)
        XCTAssertEqual(gate.reads, 1)
    }

    /// A read that answers after a snapshot is dropped; the read the snapshot started is the one that lands.
    func testAnswerFromBeforeASnapshotIsDropped() async {
        let gate = Gate(), m = model(gate)
        let old = Task { await m.loadChanges(4) }
        await gate.whenStarted()
        m.resetState()
        gate.answer(["total": 9, "added": 9, "deleted": 9])
        await old.value
        XCTAssertNil(m.changes[4], "the old answer must not land after the snapshot")
        let new = Task { await m.loadChanges(4) }
        await gate.whenStarted()
        XCTAssertEqual(m.changes[4]?.string, "wait")
        gate.answer(["total": 3, "added": 1, "deleted": 1])
        await new.value
        XCTAssertEqual(m.changes[4]?["total"].int, 3)
    }
}
