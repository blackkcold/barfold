import AppKit

/// Login-time menu bar items appear over several seconds. Collapsing before the
/// layout settles can rewrite positions and leave the bar scrambled, so wait for
/// the same fingerprint on three consecutive samples before restoring.
@MainActor
final class LaunchStabilizer {
    private var timer: Timer?
    private var lastFingerprint: String?
    private var stableSamples = 0
    private var startedAt = Date()
    private let interval: TimeInterval
    private let requiredSamples: Int
    private let maxWait: TimeInterval
    private var completion: ((Bool) -> Void)?

    init(interval: TimeInterval = 0.4, requiredSamples: Int = 3, maxWait: TimeInterval = 8) {
        self.interval = interval
        self.requiredSamples = requiredSamples
        self.maxWait = maxWait
    }

    func start(completion: @escaping (Bool) -> Void) {
        cancel()
        self.completion = completion
        startedAt = Date()
        lastFingerprint = nil
        stableSamples = 0

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        completion = nil
    }

    private func tick() {
        if Date().timeIntervalSince(startedAt) >= maxWait {
            finish(stable: false)
            return
        }

        let fingerprint = Self.fingerprint()
        if fingerprint == lastFingerprint {
            stableSamples += 1
            if stableSamples >= requiredSamples {
                finish(stable: true)
            }
        } else {
            lastFingerprint = fingerprint
            stableSamples = 0
        }
    }

    private func finish(stable: Bool) {
        let callback = completion
        cancel()
        callback?(stable)
    }

    static func fingerprint() -> String {
        let items = MenuBarProbe.statusWindows()
            .filter { $0.isOnscreen && $0.frame.width < 220 }
            .map { "\(Int($0.frame.x.rounded())):\(Int($0.frame.width.rounded()))" }
            .sorted()
        return items.joined(separator: "|")
    }
}
