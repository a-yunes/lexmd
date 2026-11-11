import AppKit
import Observation
import Sparkle

/// Signed software updates through Sparkle. Checks and installs are user choices in Settings.
@MainActor
@Observable
final class UpdateService: NSObject {
    private(set) var automaticChecks = false
    private(set) var automaticDownloads = false
    private(set) var canCheck = false
    private(set) var lastChecked: Date?
    private(set) var error: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Updates only run from a bundled app that carries a feed and public key.
    var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    func start() {
        guard controller == nil, isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            let updater = controller.updater
            observations = [
                updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.refresh() }
                },
                updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.refresh() }
                },
                updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.refresh() }
                },
                updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.refresh() }
                },
            ]
            refresh()
        } catch {
            self.error = "Updates couldn’t start. \(error.localizedDescription)"
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        automaticChecks = enabled
        controller?.updater.automaticallyChecksForUpdates = enabled
        if !enabled { setAutomaticDownloads(false) }
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        automaticDownloads = enabled
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() {
        guard canCheck else { return }
        controller?.checkForUpdates(nil)
    }

    private func refresh() {
        guard let updater = controller?.updater else { return }
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
        canCheck = updater.canCheckForUpdates
        lastChecked = updater.lastUpdateCheckDate
    }
}

extension UpdateService: SPUUpdaterDelegate {
    /// Never send system profile data with update checks.
    nonisolated func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}
