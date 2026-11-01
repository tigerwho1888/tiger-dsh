import UIKit

/// Counts late frames (hitches) while the app runs, so smoothness can be measured instead of guessed.
/// Results go to Documents/perf.json every two seconds; Settings can show them as an overlay.
@MainActor
final class FrameMonitor: NSObject {
    static let shared = FrameMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var frames = 0
    private(set) var hitches = 0          // frames that arrived later than 1.5 expected intervals
    private(set) var hitchTime: Double = 0 // seconds lost to late frames
    private(set) var worst: Double = 0     // longest frame, seconds
    private var started = CACurrentMediaTime()
    private var lastWrite: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        reset()
    }

    func reset() { frames = 0; hitches = 0; hitchTime = 0; worst = 0; last = 0; started = CACurrentMediaTime() }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let expected = l.targetTimestamp - l.timestamp
        if last > 0 {
            let dt = now - last
            // A quarter second without a tick is the app not drawing at all — backgrounded, a system sheet, a
            // debugger pause — and counting it as a hitch poisoned the numbers with the time the app was away.
            if dt > 0.25 { last = now; return }
            frames += 1
            worst = max(worst, dt)
            if expected > 0 && dt > expected * 1.5 { hitches += 1; hitchTime += dt - expected }
        }
        last = now
        if now - lastWrite > 2 { lastWrite = now; write() }
    }

    var summary: String {
        let secs = max(0.001, CACurrentMediaTime() - started)
        // The elapsed figure is what makes two readings subtractable: a UI test can read this line off the overlay
        // and turn the rates back into counts for the interval it just drove.
        return String(format: "%.0f fps · %d hitches · %.1f ms/s lost · worst %.0f ms · %.0fs", Double(frames) / secs, hitches, hitchTime * 1000 / secs, worst * 1000, secs)
    }

    private func write() {
        let secs = max(0.001, CACurrentMediaTime() - started)
        let o: [String: Double] = ["seconds": secs, "frames": Double(frames), "hitches": Double(hitches),
                                   "hitchMsPerSecond": hitchTime * 1000 / secs, "worstMs": worst * 1000]
        // The snapshot is taken here (it reads main-actor state) but serialized and written off the main thread:
        // this used to run inside the very callback that judges lateness, so the instrument caused hitches it
        // then recorded.
        let url = Self.outputURL
        Task.detached(priority: .utility) {
            guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
            try? d.write(to: url, options: .atomic)
        }
    }

    /// `DSH_PERF_OUT` names the file from the launch environment so a test can read the numbers at a path it
    /// knows; the app's own Documents/perf.json stays the default.
    static var outputURL: URL {
        if let p = ProcessInfo.processInfo.environment["DSH_PERF_OUT"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("perf.json")
    }
}
