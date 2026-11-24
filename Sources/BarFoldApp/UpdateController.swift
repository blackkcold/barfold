import AppKit
import BarFoldProtocol
import Sparkle

/// Wraps Sparkle 2. A build without a real `SUPublicEDKey` (every ad-hoc
/// development build) stays completely inert, so the app never starts an
/// updater that cannot verify its feed.
@objcMembers
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private let feedURL: String
    private(set) var isConfigured = false
    private(set) var updateAvailable = false
    private(set) var lastError: String?

    var onStatusChange: (() -> Void)?
    var onUpdateFound: (() -> Void)?

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        feedURL = (info["SUFeedURL"] as? String) ?? ""
        super.init()

        let key = (info["SUPublicEDKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feedURL.isEmpty,
              !key.isEmpty,
              !key.hasPrefix("PLACEHOLDER") else {
            isConfigured = false
            return
        }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        isConfigured = true
    }

    /// Returns false when this build has no usable Sparkle configuration.
    func checkForUpdates() -> Bool {
        guard let controller else { return false }
        controller.checkForUpdates(nil)
        return true
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    var status: JSONValue {
        .object([
            "configured": .bool(isConfigured),
            "automaticallyChecks": .bool(controller?.updater.automaticallyChecksForUpdates ?? false),
            "updateAvailable": .bool(updateAvailable),
            "feedURL": .string(feedURL),
            "lastError": .string(lastError ?? ""),
        ])
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailable = true
        onUpdateFound?()
        onStatusChange?()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        updateAvailable = false
        lastError = error.localizedDescription
        onStatusChange?()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        lastError = error.localizedDescription
        onStatusChange?()
    }
}
