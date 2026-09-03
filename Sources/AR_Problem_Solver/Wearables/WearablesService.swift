import Foundation
import Observation
import MWDATCore

/// Owns SDK configuration and the top-level authorization / connection state.
/// One instance, created at app launch and shared with the camera and display
/// services.
@MainActor
@Observable
final class WearablesService {
    private(set) var registrationState: RegistrationState
    private(set) var deviceNames: [String] = []
    /// True when a connected device reports it needs a firmware update.
    private(set) var requiresFirmwareUpdate = false
    /// True when session start reported the on-glasses DAT app is too old.
    private(set) var requiresGlassesAppUpdate = false
    var lastError: String?

    /// The live SDK facade. Injected so tests can pass a stand-in.
    let wearables: WearablesInterface

    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var compatibilityTokens: [DeviceIdentifier: AnyListenerToken] = [:]
    @ObservationIgnored private var compatibilityByDevice: [DeviceIdentifier: Compatibility] = [:]

    /// Configures the SDK exactly once, then returns a service bound to
    /// `Wearables.shared`. Safe to call even if configuration fails — the
    /// service still exists so the UI can show the error.
    static func makeConfigured() -> WearablesService {
        do {
            try Wearables.configure()
        } catch {
            AppLog.wearables.error("Wearables.configure() failed: \(String(describing: error))")
        }
        return WearablesService(wearables: Wearables.shared)
    }

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.registrationState = wearables.registrationState

        registrationTask = Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                guard let self else { return }
                self.registrationState = state
                AppLog.wearables.info("registrationState → \(String(describing: state))")
                // Authorization dropped: forget any device-scoped state.
                if state == .available || state == .unavailable {
                    self.requiresGlassesAppUpdate = false
                }
            }
        }
        deviceTask = Task { [weak self] in
            for await ids in wearables.devicesStream() {
                self?.refreshDevices(ids)
            }
        }
    }

    deinit {
        registrationTask?.cancel()
        deviceTask?.cancel()
    }

    // MARK: - Derived state

    /// The app is authorized for the glasses and can create sessions.
    /// `.registered` — NOT `.available` (which only means glasses are reachable
    /// but this app hasn't completed the Meta AI authorization handshake).
    var isAuthorized: Bool { registrationState == .registered }

    var isConnecting: Bool { registrationState == .registering }

    /// A short human-readable status for the companion UI / logs.
    var connectionSummary: String {
        switch registrationState {
        case .unavailable: return "Meta AI not set up"
        case .available: return "Glasses found — not connected to this app"
        case .registering: return "Connecting…"
        case .registered:
            if requiresGlassesAppUpdate { return "Glasses app update required" }
            if requiresFirmwareUpdate { return "Firmware update required" }
            return deviceNames.isEmpty ? "Connected — waiting for glasses" : "Connected: \(deviceNames.joined(separator: ", "))"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Actions

    func connect() async {
        guard registrationState != .registering else { return }
        do {
            try await wearables.startRegistration()
        } catch {
            lastError = errorText(error)
            AppLog.wearables.error("startRegistration failed: \(self.errorText(error))")
        }
    }

    func disconnect() async {
        do {
            try await wearables.startUnregistration()
        } catch {
            lastError = errorText(error)
        }
    }

    func openFirmwareUpdate() async {
        do { try await wearables.openFirmwareUpdate() } catch { lastError = errorText(error) }
    }

    func openGlassesAppUpdate() async {
        do { try await wearables.openDATGlassesAppUpdate() } catch { lastError = errorText(error) }
    }

    /// Called by the display service when a session reports the on-glasses app is stale.
    func noteGlassesAppUpdateRequired() {
        requiresGlassesAppUpdate = true
    }

    /// Route the Meta AI callback URL into the SDK. Only URLs that carry the
    /// `metaWearablesAction` query item are DAT callbacks — everything else is
    /// ignored so unrelated deep links don't reach the SDK.
    func handle(url: URL) {
        let isDATCallback = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "metaWearablesAction" } ?? false
        guard isDATCallback else { return }
        Task { [weak self] in
            do {
                _ = try await self?.wearables.handleUrl(url)
            } catch {
                self?.lastError = self?.errorText(error) ?? "\(error)"
            }
        }
    }

    // MARK: - Devices / compatibility

    private func refreshDevices(_ ids: [DeviceIdentifier]) {
        deviceNames = ids.compactMap { wearables.deviceForIdentifier($0)?.nameOrId() }

        let live = Set(ids)
        for id in compatibilityTokens.keys where !live.contains(id) {
            compatibilityTokens[id] = nil
            compatibilityByDevice[id] = nil
        }
        for id in ids {
            guard compatibilityTokens[id] == nil, let device = wearables.deviceForIdentifier(id) else { continue }
            compatibilityByDevice[id] = device.compatibility()
            compatibilityTokens[id] = device.addCompatibilityListener { [weak self] compatibility in
                Task { @MainActor in
                    self?.compatibilityByDevice[id] = compatibility
                    self?.recomputeFirmwareFlag()
                }
            }
        }
        recomputeFirmwareFlag()
    }

    private func recomputeFirmwareFlag() {
        requiresFirmwareUpdate = compatibilityByDevice.values.contains(.deviceUpdateRequired)
    }

    private func errorText(_ error: Error) -> String {
        (error as? DatError)?.errorDescription ?? error.localizedDescription
    }
}
