import Foundation
import Observation
import MWDATCore
import MWDATCamera

/// Quick-snap still capture over the DAT camera.
///
/// DAT 0.9 has no stream-less photo API — `Stream.capturePhoto(_:)` requires an
/// active `Stream`. So this opens a stream at the lowest frame rate, fires
/// `capturePhoto` the instant it reaches `.streaming`, and **stops the camera in
/// the same callback that delivers the photo** — the privacy light is on only
/// for the ~1 s between "streaming" and "photo captured", never for the Claude
/// call or teardown.
///
/// FUTURE: this creates and destroys its own `DeviceSession` per capture. If a
/// future revision needs camera + display live at once, hoist a single shared
/// `DeviceSession` into `WearablesService` and add both capabilities to it.
@MainActor
@Observable
final class GlassesCameraService: PhotoCapturing {
    enum Phase: Equatable {
        case idle, checkingPermission, startingSession, startingStream, capturing, done
    }

    private(set) var phase: Phase = .idle

    /// Whether the auto-selector currently has an eligible device. Kept live from
    /// `init` so a capture doesn't race device discovery.
    private(set) var hasActiveDevice: Bool = false

    private let wearables: WearablesInterface
    /// One long-lived selector — created once (like the CameraAccess sample), so
    /// `activeDeviceStream()` has had time to discover the glasses before the
    /// user taps Capture.
    @ObservationIgnored private let deviceSelector: AutoDeviceSelector
    @ObservationIgnored private let tokens = ListenerTokenBag()
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: MWDATCamera.Camera?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
    /// Set after the first capture that hit a permission wall, so the next capture
    /// is allowed to trigger the Meta AI redirect (`requestPermission`).
    @ObservationIgnored private var mayRequestPermission = false

    /// Per-phase timeout. Generous — Bluetooth Classic setup is slow.
    var timeout: Duration = .seconds(30)
    /// How long to wait for the auto-selector to surface a device before failing.
    var deviceWait: Duration = .seconds(12)

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
        self.hasActiveDevice = deviceSelector.activeDevice != nil
        deviceMonitorTask = Task { [weak self] in
            guard let selector = self?.deviceSelector else { return }
            for await id in selector.activeDeviceStream() {
                self?.hasActiveDevice = id != nil
            }
        }
    }

    deinit {
        deviceMonitorTask?.cancel()
    }

    func capturePhoto() async throws -> Data {
        defer { teardown() }

        guard wearables.registrationState == .registered else {
            throw GlassesError.notAuthorized
        }

        // Wait for a device before anything else — a permission check or
        // createSession that races discovery both surface as "no device".
        phase = .startingSession
        try await waitForActiveDevice()

        try await ensureCameraPermission()

        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: deviceSelector)
        } catch {
            throw mapSessionError(error)
        }
        self.session = session

        do {
            try session.start()
        } catch {
            throw mapSessionError(error)
        }
        try await waitForSessionStarted(session)

        phase = .startingStream
        // Lowest frame rate — a snap needs no continuous frames, and less
        // Bluetooth traffic means a faster path to `.streaming` and the shutter.
        let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 2)
        let created: MWDATCamera.Camera?
        do {
            created = try session.addCamera(config: config)
        } catch {
            throw mapSessionError(error)
        }
        guard let camera = created else {
            throw GlassesError.sessionFailed("Session not ready for a camera.")
        }
        self.camera = camera

        let photoData = try await withStream(on: camera)
        phase = .done
        AppLog.camera.info("Snapped \(photoData.count) bytes; camera stopped")
        return photoData
    }

    // MARK: - Permission

    private func ensureCameraPermission() async throws {
        phase = .checkingPermission
        do {
            if try await wearables.checkPermissionStatus(.camera) == .granted { return }
        } catch {
            throw Self.mapPermission(error)
        }

        guard mayRequestPermission else {
            // First hit: don't app-switch mid-flow. Arm the redirect for next time.
            mayRequestPermission = true
            throw GlassesError.cameraPermissionNeeded
        }

        // Opens the Meta AI app and resumes when the user returns.
        do {
            let result = try await wearables.requestPermission(.camera)
            guard result == .granted else { throw GlassesError.cameraPermissionDenied }
        } catch {
            throw Self.mapPermission(error)
        }
    }

    /// Maps a DAT `PermissionError` (or a `GlassesError` thrown from the guard)
    /// to a specific `GlassesError`.
    private static func mapPermission(_ error: any Error) -> GlassesError {
        if let already = error as? GlassesError { return already }
        guard let permission = error as? PermissionError else {
            return .sessionFailed(error.localizedDescription)
        }
        switch permission {
        case .metaAINotInstalled: return .metaAINotInstalled
        case .noDevice, .noDeviceWithConnection: return .notConnected
        case .requestInProgress: return .permissionRequestInProgress
        case .requestTimeout: return .timedOut("the Meta AI permission prompt")
        case .connectionError: return .sessionFailed("Lost the connection to the glasses.")
        case .internalError: return .sessionFailed(permission.errorDescription ?? "Permission check failed.")
        @unknown default: return .cameraPermissionDenied
        }
    }

    // MARK: - Lifecycle waits

    /// Blocks until the auto-selector reports an eligible device, or throws
    /// `.notConnected` after `deviceWait`. Prevents `createSession` from racing
    /// device discovery right after launch (which surfaces as `noEligibleDevice`).
    private func waitForActiveDevice() async throws {
        if deviceSelector.activeDevice != nil { return }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [deviceSelector] in
                    for await id in deviceSelector.activeDeviceStream() where id != nil { return }
                }
                group.addTask { [deviceWait] in
                    try await Task.sleep(for: deviceWait)
                    throw GlassesError.notConnected
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch is CancellationError {
            // fine
        }
        guard deviceSelector.activeDevice != nil else { throw GlassesError.notConnected }
    }

    private func waitForSessionStarted(_ session: DeviceSession) async throws {
        try await withTimeout(phase: "the glasses session") {
            for await state in session.stateStream() {
                if state == .started { return }
                if state == .stopped { throw GlassesError.sessionFailed("Session stopped before starting.") }
            }
            throw GlassesError.sessionFailed("Session state stream ended.")
        }
    }

    /// Starts the stream, fires the shutter on `.streaming`, and stops the camera
    /// the instant the photo arrives (or on any failure) so the privacy light is
    /// lit for the shortest possible window.
    private func withStream(on camera: MWDATCamera.Camera) async throws -> Data {
        let stream = camera.stream
        return try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)

            // Cuts the camera immediately, then resumes the caller.
            let finish: @Sendable (Result<Data, Error>) -> Void = { result in
                camera.stop()
                switch result {
                case .success(let data): box.succeed(data)
                case .failure(let error): box.fail(error)
                }
            }

            stream.statePublisher.listen { state in
                if state == .streaming {
                    Task { @MainActor in
                        self.phase = .capturing
                        if !stream.capturePhoto(format: .jpeg) {
                            finish(.failure(GlassesError.captureFailed("capturePhoto returned false.")))
                        }
                    }
                } else if state == .stopped {
                    finish(.failure(GlassesError.captureFailed("Stream stopped before a photo arrived.")))
                }
            }.store(in: tokens)

            stream.errorPublisher.listen { error in
                finish(.failure(GlassesError.captureFailed(error.localizedDescription)))
            }.store(in: tokens)

            stream.photoDataPublisher.listen { photo in
                finish(.success(photo.data))
            }.store(in: tokens)

            stream.start()

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: self.timeout)
                guard !Task.isCancelled else { return }
                finish(.failure(GlassesError.timedOut("a photo from the glasses")))
            }
        }
    }

    private func withTimeout(phase: String, _ work: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw GlassesError.timedOut(phase)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func mapSessionError(_ error: DeviceSessionError) -> GlassesError {
        switch error {
        case .noEligibleDevice:
            return .notConnected
        case .datAppOnTheGlassesUpdateRequired:
            return .glassesAppUpdateRequired
        case .capabilityAlreadyActive, .sessionAlreadyExists:
            return .sessionFailed("A glasses session is already open. Try again in a moment.")
        case .thermalCritical, .thermalEmergency:
            return .sessionFailed("The glasses are too warm. Let them cool down and try again.")
        case .batteryCritical, .peakPowerShutdown:
            return .sessionFailed("The glasses battery is too low.")
        default:
            return .sessionFailed(error.errorDescription ?? "The glasses session failed.")
        }
    }

    private func teardown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        tokens.clear()
        camera?.stop()
        camera = nil
        session?.stop()
        session = nil
        if phase != .done { phase = .idle }
    }
}

/// Guards a checked continuation so it resumes exactly once from multiple
/// publisher callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
