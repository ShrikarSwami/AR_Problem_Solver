import Foundation
import Observation

/// Composition root. Owns the long-lived services and the coordinator, wired to
/// the live DAT SDK. Created once by the app entry point.
@MainActor
@Observable
final class AppModel {
    let wearables: WearablesService
    let camera: GlassesCameraService
    let display: GlassesDisplayService
    let coordinator: SolverCoordinator

    @ObservationIgnored private var homeWatchTask: Task<Void, Never>?

    /// Whether a Claude API key is available from any source.
    var hasAPIKey: Bool {
        KeychainStore.readAPIKey() != nil || !Secrets.anthropicAPIKey.isEmpty
    }

    /// Lightweight, unbilled check that the key + network reach Anthropic.
    func checkClaudeConnection() async -> ClaudeConnection {
        await ClaudeClient().checkConnection()
    }

    init() {
        let wearables = WearablesService.makeConfigured()
        let camera = GlassesCameraService(wearables: wearables.wearables)
        let display = GlassesDisplayService(wearables: wearables.wearables)
        display.onGlassesAppUpdateRequired = { [weak wearables] in
            wearables?.noteGlassesAppUpdateRequired()
        }

        self.wearables = wearables
        self.camera = camera
        self.display = display
        self.coordinator = SolverCoordinator(
            camera: camera,
            solver: ClaudeClient(),
            display: display,
            isDeviceReady: { [weak wearables] in wearables?.isAuthorized ?? false }
        )

        // Re-show the glasses home screen whenever a run finishes.
        coordinator.onIdle = { [weak self] in await self?.sendGlassesHome() }

        // Glasses-first: push the home menu to the display as soon as the glasses
        // are authorised and discovered, and again if that state flips back on.
        homeWatchTask = Task { [weak self] in
            var wasReady = false
            while !Task.isCancelled {
                let ready = self?.isGlassesReady ?? false
                if ready && !wasReady { await self?.sendGlassesHome() }
                wasReady = ready
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    deinit { homeWatchTask?.cancel() }

    func handle(url: URL) {
        wearables.handle(url: url)
    }

    var isGlassesReady: Bool {
        wearables.isAuthorized && camera.hasActiveDevice
    }

    /// Sends the home menu to the glasses if idle and ready. The "Scan" button is
    /// driven by a Neural Band tap.
    func sendGlassesHome() async {
        guard isGlassesReady, coordinator.state == .idle else { return }
        let page = TeleprompterDisplay.home { [weak self] in
            Task { @MainActor in await self?.coordinator.solve() }
        }
        try? await display.send(page)
    }
}
