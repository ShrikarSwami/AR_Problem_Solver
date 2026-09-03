import Foundation
import Observation
import MWDATCore
import MWDATDisplay

/// Manages the display-session lifecycle: attach to a display-capable device,
/// send layouts, detach. `send(_:)` connects on demand and **throws** if the
/// session can't be established, so the coordinator surfaces a real error
/// instead of silently queuing a page that never appears.
@MainActor
@Observable
final class GlassesDisplayService: DisplaySending {
    private(set) var isConnected: Bool = false
    private(set) var isSending: Bool = false
    var lastError: String?

    /// Called when a session reports the on-glasses DAT app is too old.
    var onGlassesAppUpdateRequired: (() -> Void)?

    private let wearables: WearablesInterface
    @ObservationIgnored private var deviceSelector: AutoDeviceSelector
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private let tokens = ListenerTokenBag()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var sessionErrorTask: Task<Void, Never>?
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var registrationTask: Task<Void, Never>?

    /// How long to wait for the session + display to come up.
    var connectTimeout: Duration = .seconds(30)

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
        observeRegistration()
    }

    deinit {
        registrationTask?.cancel()
        sessionTask?.cancel()
        sessionErrorTask?.cancel()
        displayTask?.cancel()
    }

    // MARK: - DisplaySending

    func send(_ page: FlexBox) async throws {
        if display == nil || !isConnected {
            try await connect()
        }
        guard let display else { throw GlassesError.sessionFailed("Display went away before send.") }

        isSending = true
        defer { isSending = false }
        do {
            try await display.send(page)
        } catch {
            let message = (error as? DisplayError)?.description ?? error.localizedDescription
            lastError = message
            throw GlassesError.sessionFailed(message)
        }
    }

    func end() {
        display?.stop()
        session?.stop()
        tokens.clear()
        sessionTask?.cancel(); sessionTask = nil
        sessionErrorTask?.cancel(); sessionErrorTask = nil
        displayTask?.cancel(); displayTask = nil
        display = nil
        session = nil
        isConnected = false
    }

    // MARK: - Connect

    private func connect() async throws {
        guard wearables.registrationState == .registered else { throw GlassesError.notAuthorized }
        end() // clear any half-open state

        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: deviceSelector)
        } catch {
            throw Self.mapSessionError(error, notifyUpdate: onGlassesAppUpdateRequired)
        }
        self.session = session

        // One long-lived consumer of the session state stream; signals readiness
        // and keeps `isConnected` accurate for the rest of the session's life.
        let sessionReady = AsyncOneShot()
        sessionTask = Task { [weak self] in
            for await state in session.stateStream() {
                guard let self else { return }
                switch state {
                case .started:
                    sessionReady.succeed()
                case .stopped:
                    sessionReady.fail(GlassesError.sessionFailed("The glasses session stopped before it was ready."))
                    self.isConnected = false
                case .stopping:
                    self.isConnected = false
                default:
                    break
                }
            }
            sessionReady.fail(GlassesError.sessionFailed("The glasses session ended unexpectedly."))
        }
        sessionErrorTask = Task { [weak self] in
            for await error in session.errorStream() {
                guard let self else { return }
                self.lastError = error.localizedDescription
                if error == .datAppOnTheGlassesUpdateRequired { self.onGlassesAppUpdateRequired?() }
            }
        }

        try await withTimeout("the glasses display") { [self] in
            do {
                try session.start()
            } catch {
                throw Self.mapSessionError(error, notifyUpdate: onGlassesAppUpdateRequired)
            }
            try await sessionReady.value

            let display: Display
            do {
                display = try session.addDisplay()
            } catch {
                throw Self.mapSessionError(error, notifyUpdate: onGlassesAppUpdateRequired)
            }
            self.display = display

            let displayReady = AsyncOneShot()
            let (states, continuation) = AsyncStream.makeStream(of: DisplayState.self)
            display.statePublisher.listen { continuation.yield($0) }.store(in: tokens)
            displayTask = Task { [weak self] in
                for await state in states {
                    guard let self else { return }
                    switch state {
                    case .started:
                        displayReady.succeed()
                        self.isConnected = true
                    case .stopping, .stopped:
                        displayReady.fail(GlassesError.sessionFailed("The display stopped before it was ready."))
                        self.isConnected = false
                    default:
                        break
                    }
                }
            }
            display.start()
            try await displayReady.value
        }
    }

    // MARK: - Registration observer

    private func observeRegistration() {
        registrationTask = Task { [weak self] in
            guard let wearables = self?.wearables else { return }
            for await state in wearables.registrationStateStream() {
                guard let self else { return }
                // Authorization lost — tear the session down and refresh the selector.
                if state == .available || state == .unavailable {
                    self.end()
                    self.deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
                }
            }
        }
    }

    // MARK: - Helpers

    private func withTimeout(_ phase: String, _ work: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask { [connectTimeout] in
                try await Task.sleep(for: connectTimeout)
                throw GlassesError.timedOut(phase)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private static func mapSessionError(_ error: any Error, notifyUpdate: (() -> Void)?) -> GlassesError {
        if let already = error as? GlassesError { return already }
        guard let session = error as? DeviceSessionError else {
            return .sessionFailed(error.localizedDescription)
        }
        switch session {
        case .noEligibleDevice:
            return .notConnected
        case .datAppOnTheGlassesUpdateRequired:
            notifyUpdate?()
            return .glassesAppUpdateRequired
        case .capabilityAlreadyActive, .sessionAlreadyExists:
            return .sessionFailed("A glasses session is already open. Try again in a moment.")
        case .thermalCritical, .thermalEmergency:
            return .sessionFailed("The glasses are too warm. Let them cool down and try again.")
        case .batteryCritical, .peakPowerShutdown:
            return .sessionFailed("The glasses battery is too low.")
        default:
            return .sessionFailed(session.errorDescription ?? "The glasses session failed.")
        }
    }
}

/// A one-time `Void` signal bridged to `async`. Safe to resolve from multiple
/// stream callbacks — only the first wins.
final class AsyncOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled: Result<Void, Error>?

    var value: Void {
        get async throws {
            try await withCheckedThrowingContinuation { cont in
                lock.lock(); defer { lock.unlock() }
                if let settled {
                    cont.resume(with: settled)
                } else {
                    continuation = cont
                }
            }
        }
    }

    func succeed() { settle(.success(())) }
    func fail(_ error: Error) { settle(.failure(error)) }

    private func settle(_ result: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard settled == nil else { return }
        settled = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
