import Foundation
import Observation
import MWDATCore

/// Owns SDK configuration and top-level registration state. One instance,
/// created at app launch and shared with the camera and display services.
@MainActor
@Observable
final class WearablesService {
    private(set) var registrationState: RegistrationState
    private(set) var deviceNames: [String] = []
    var lastError: String?

    /// The live SDK facade. Injected so tests can pass a stand-in.
    let wearables: WearablesInterface

    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var deviceTask: Task<Void, Never>?

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
                self?.registrationState = state
            }
        }
        deviceTask = Task { [weak self] in
            for await ids in wearables.devicesStream() {
                self?.deviceNames = ids.compactMap { wearables.deviceForIdentifier($0)?.nameOrId() }
            }
        }
    }

    deinit {
        registrationTask?.cancel()
        deviceTask?.cancel()
    }

    var isRegistered: Bool { registrationState == .available }

    func connect() async {
        guard registrationState != .registering else { return }
        do {
            try await wearables.startRegistration()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        do {
            try await wearables.startUnregistration()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Route the Meta AI callback URL into the SDK.
    func handle(url: URL) {
        Task { _ = try? await wearables.handleUrl(url) }
    }
}
