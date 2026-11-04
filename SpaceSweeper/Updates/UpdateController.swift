import Foundation
import Observation
import Sparkle

/// Whether this build has what Sparkle needs to update safely: an https appcast URL and an EdDSA public key.
enum UpdateConfiguration {
    /// Valid when the feed is an https URL and the key looks like a base64 Ed25519 public key (32 bytes).
    static func isValid(feedURL: String?, publicKey: String?) -> Bool {
        guard let feedURL, let url = URL(string: feedURL), url.scheme == "https", url.host != nil else { return false }
        guard let publicKey, let data = Data(base64Encoded: publicKey), data.count == 32 else { return false }
        return true
    }

    static func isValid(bundle: Bundle) -> Bool {
        isValid(feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }
}

/// Wraps Sparkle's standard updater. Sparkle is only started when the build is configured for updates,
/// so unconfigured builds never show update errors to users.
@MainActor
@Observable
final class UpdateController {
    /// False until a feed URL and signing key are set in the build settings (see README › Releasing updates).
    let isConfigured: Bool
    /// Mirrors Sparkle's `canCheckForUpdates` (false while a check is already running).
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        isConfigured = UpdateConfiguration.isValid(bundle: bundle)
        if isConfigured {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            self.controller = controller
            observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let canCheck = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheckForUpdates = canCheck }
            }
        } else {
            controller = nil
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Sparkle's own preference, persisted by Sparkle in the app's defaults.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}
