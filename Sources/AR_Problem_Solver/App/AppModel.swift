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
    }

    func handle(url: URL) {
        wearables.handle(url: url)
    }
}
