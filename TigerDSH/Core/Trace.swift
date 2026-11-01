import os

#if DEBUG || targetEnvironment(simulator)
import Foundation

/// Named moments, body counts and a stall watchdog for the Simulator. Simulator and DEBUG builds only; every call is
/// a no-op elsewhere.
///
/// Why this exists at all: the Time Profiler's samples on a Simulator trace come back as raw addresses and
/// `xctrace symbolicate` refuses the trace ("No dSYMs were found or relevant to this trace") even with the matching
/// dSYM beside it, and `xctrace export` refuses the os-signpost table ("Document Missing Template Error"). So the
/// marks are read from the simulator's unified log — filtered to this subsystem, never a raw log — and the stall
/// watchdog answers the question the profiler would have: which mark was open when the main thread stopped.
enum Trace {
    private static let log = OSLog(subsystem: "com.tigerwho.dshphone", category: .pointsOfInterest)
    private static let lock = NSLock()

    /// `lock` is what makes these safe, and the watchdog reads them from a thread of its own, so the promise is
    /// stated rather than inferred: every read and every write below is inside `lock`.
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var openMark = ""
    nonisolated(unsafe) private static var lastFlush = CFAbsoluteTimeGetCurrent()

    static func id() -> OSSignpostID { OSSignpostID(log: log) }

    /// A moment: "this happened, at this time".
    static func mark(_ name: StaticString, _ detail: String = "") {
        if detail.isEmpty {
            os_signpost(.event, log: log, name: name)
        } else {
            os_signpost(.event, log: log, name: name, "%{public}s", detail)
        }
    }

    /// A duration: "this took this long". The open mark is what the watchdog reports at a stall.
    static func begin(_ name: StaticString, _ id: OSSignpostID) {
        lock.lock(); openMark = "\(name)"; lock.unlock()
        os_signpost(.begin, log: log, name: name, signpostID: id)
    }

    static func end(_ name: StaticString, _ id: OSSignpostID) {
        lock.lock(); if openMark == "\(name)" { openMark = "" }; lock.unlock()
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    /// One per SwiftUI body evaluation. Counted, not logged per call: a body that re-runs on every frame of an
    /// interactive transition is the cost this is looking for, and the count is the evidence.
    static func body(_ name: StaticString) {
        lock.lock()
        counts["\(name)", default: 0] += 1
        totals["\(name)", default: 0] += 1
        lock.unlock()
        flushIfDue()
    }

    /// Counts that survive the two-second flush. `flushIfDue` empties `counts`, so a measurement that reads a count
    /// after the fact would find nothing — and the geometry handler is exactly the count a test wants to read
    /// afterwards ("this flick produced N callbacks, and a still screen produced none"). Only a test resets these.
    nonisolated(unsafe) private static var totals: [String: Int] = [:]

    static func total(_ name: StaticString) -> Int {
        lock.lock(); defer { lock.unlock() }
        return totals["\(name)"] ?? 0
    }

    /// A counted moment that is NOT a body pass. `body` counts passes; this counts decisions — the pull's own
    /// branches are the ones a unit test has to tell apart ("asked for a page" / "spent the hold" / "the hold was
    /// gone by the time the page's rows were laid out"), and a count survives the flush the same way `body`'s does.
    static func count(_ name: StaticString) {
        lock.lock(); totals["\(name)", default: 0] += 1; lock.unlock()
    }

    static func resetTotal(_ name: StaticString) {
        lock.lock(); totals["\(name)"] = 0; lock.unlock()
    }

    /// Counted per ROW-LIST REBUILD, not per body pass: the chat list's own rebuild is what a jump's cost is
    /// measured in, and a pass that changed nothing does not rebuild (that is the point of the cached row list).
    nonisolated(unsafe) private static var builds = 0
    /// What those rebuilds cost in total, so a jump can be judged as "N rebuilds, M ms" rather than by the count
    /// alone — the list grows under a jump, so the last rebuild is the expensive one.
    nonisolated(unsafe) private static var rebuildMs = 0.0
    /// The rebuild count SINCE THE LAST `takeRebuilds()`, kept out of `counts` because both flush paths clear that
    /// whole dictionary — the two-second one and the 64th rebuild's own — so a gesture's count was erased by a flush
    /// while its cost stayed in `rebuildMs`, and a measured jump read as a fraction of its rebuilds (Codex R6 P3).
    /// Only `takeRebuilds()` resets this one.
    nonisolated(unsafe) private static var rebuildCount = 0
    /// Every 64 rebuilds, one line: fine-grained enough to attribute a jump's own cost to the jump, sparse enough
    /// that a long list materialising is a handful of lines rather than thousands.
    static func rebuilt(_ name: StaticString) {
        lock.lock()
        counts["rebuild.\(name)", default: 0] += 1
        rebuildCount += 1
        builds += 1
        let due = builds % 64 == 0
        lock.unlock()
        if due { flush() }
    }

    static func rebuildCost(_ ms: Double) {
        lock.lock(); rebuildMs += ms; lock.unlock()
    }

    /// The rebuild count and cost SINCE THE LAST READ, for a measurement that wants one gesture's own numbers.
    static func takeRebuilds() -> (count: Int, ms: Double) {
        lock.lock()
        let n = rebuildCount
        let ms = rebuildMs
        rebuildCount = 0
        rebuildMs = 0
        lock.unlock()
        return (n, ms)
    }

    /// Every two seconds the counts and the currently open mark go out as one line, so a gate's window reads as
    /// "this body ran N times, and the stall landed inside this mark".
    static func flushIfDue() {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFlush >= 2, !counts.isEmpty else { lock.unlock(); return }
        lastFlush = now
        let line = counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        counts.removeAll()
        let open = openMark
        lock.unlock()
        mark("bodies", line + (open.isEmpty ? "" : " open=\(open)"))
    }

    private static func flush() {
        lock.lock()
        lastFlush = CFAbsoluteTimeGetCurrent()
        let line = counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        counts.removeAll()
        let open = openMark
        lock.unlock()
        mark("bodies", line + (open.isEmpty ? "" : " open=\(open)"))
    }

    private nonisolated(unsafe) static var started = false

    /// A background thread pings the main thread every 50 ms. A ping that takes longer than 100 ms is a stall, and
    /// the mark that was open when it happened is the answer a symbol-less profile cannot give.
    static func startWatchdog() {
        lock.lock(); if started { lock.unlock(); return }; started = true; lock.unlock()
        let thread = Thread {
            while true {
                let t0 = CFAbsoluteTimeGetCurrent()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                _ = done.wait(timeout: .now() + 2)
                let dt = CFAbsoluteTimeGetCurrent() - t0
                if dt > 0.1 {
                    lock.lock(); let open = openMark; lock.unlock()
                    mark("stall", String(format: "%.0fms open=%@", dt * 1000, open.isEmpty ? "-" : open))
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "dsh-trace-watchdog"
        thread.start()
    }
}
#else
/// Nothing is recorded on a device build: the names would be dead weight in a shipping binary.
enum Trace {
    static func mark(_ name: StaticString, _ detail: String = "") {}
    static func begin(_ name: StaticString, _ id: OSSignpostID) {}
    static func end(_ name: StaticString, _ id: OSSignpostID) {}
    static func body(_ name: StaticString) {}
    static func total(_ name: StaticString) -> Int { 0 }
    static func count(_ name: StaticString) {}
    static func resetTotal(_ name: StaticString) {}
    static func rebuilt(_ name: StaticString) {}
    static func rebuildCost(_ ms: Double) {}
    static func takeRebuilds() -> (count: Int, ms: Double) { (0, 0) }
    static func flushIfDue() {}
    static func startWatchdog() {}
}
#endif
