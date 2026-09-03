import Foundation
import Observation
import MWDATCore
import MWDATCamera

/// Drives the DAT camera lifecycle for a single still capture:
/// create session → start → add camera → start stream → wait for frames →
/// `capturePhoto(.jpeg)` → first `PhotoData` → tear everything down.
///
/// Mirrors the `CameraAccess` sample's explicit-steps approach, collapsed to the
/// one path this app needs.
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

    private let wearables: WearablesInterface
    @ObservationIgnored private let tokens = ListenerTokenBag()
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: MWDATCamera.Camera?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    /// Set after the first capture that hit a permission wall, so the next capture
    /// is allowed to trigger the Meta AI redirect (`requestPermission`).
    @ObservationIgnored private var mayRequestPermission = false

    /// Per-phase timeout. Generous — Bluetooth Classic setup is slow.
    var timeout: Duration = .seconds(30)

    init(wearables: WearablesInterface) {
        self.wearables = wearables
    }

    func capturePhoto() async throws -> Data {
        defer { teardown() }

        try await ensureCameraPermission()

        phase = .startingSession
        let selector = AutoDeviceSelector(wearables: wearables)
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: selector)
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
        let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 24)
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

        let photoData = try await withStream(camera.stream)
        phase = .done
        return photoData
    }

    // MARK: - Permission

    private func ensureCameraPermission() async throws {
        phase = .checkingPermission
        let status: PermissionStatus
        do {
            status = try await wearables.checkPermissionStatus(.camera)
        } catch {
            // Treat a failed status check as "unknown" — fall through to a request
            // if we're allowed to, otherwise ask the user to retry.
            status = .denied
        }
        if status == .granted { return }

        guard mayRequestPermission else {
            // First hit: don't app-switch mid-flow. Arm the redirect for next time.
            mayRequestPermission = true
            throw GlassesError.cameraPermissionNeeded
        }

        let requested = (try? await wearables.requestPermission(.camera)) ?? .denied
        guard requested == .granted else { throw GlassesError.cameraPermissionDenied }
    }

    // MARK: - Lifecycle waits

    private func waitForSessionStarted(_ session: DeviceSession) async throws {
        try await withTimeout(phase: "the glasses session") {
            for await state in session.stateStream() {
                if state == .started { return }
                if state == .stopped { throw GlassesError.sessionFailed("Session stopped before starting.") }
            }
            throw GlassesError.sessionFailed("Session state stream ended.")
        }
    }

    /// Starts the stream, waits for the first photo, returns its JPEG bytes.
    private func withStream(_ stream: MWDATCamera.Stream) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)

            stream.statePublisher.listen { state in
                if state == .streaming {
                    Task { @MainActor in
                        self.phase = .capturing
                        if !stream.capturePhoto(format: .jpeg) {
                            box.fail(GlassesError.captureFailed("capturePhoto returned false."))
                        }
                    }
                } else if state == .stopped {
                    box.fail(GlassesError.captureFailed("Stream stopped before a photo arrived."))
                }
            }.store(in: tokens)

            stream.errorPublisher.listen { error in
                box.fail(GlassesError.captureFailed(error.localizedDescription))
            }.store(in: tokens)

            stream.photoDataPublisher.listen { photo in
                box.succeed(photo.data)
            }.store(in: tokens)

            stream.start()

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: self.timeout)
                guard !Task.isCancelled else { return }
                box.fail(GlassesError.timedOut("a photo from the glasses"))
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
            return .noDevice
        default:
            return .sessionFailed(error.localizedDescription)
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
