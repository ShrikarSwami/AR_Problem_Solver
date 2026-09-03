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
@MainActor
@Observable
final class GlassesCameraService: PhotoCapturing {
    enum Phase: Equatable {
        case idle, startingSession, startingStream, capturing, done
    }

    private(set) var phase: Phase = .idle

    private let wearables: WearablesInterface
    @ObservationIgnored private let tokens = ListenerTokenBag()
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: MWDATCamera.Camera?

    /// Per-phase timeout. Generous — Bluetooth Classic setup is slow.
    var timeout: Duration = .seconds(30)

    init(wearables: WearablesInterface) {
        self.wearables = wearables
    }

    func capturePhoto() async throws -> Data {
        defer { teardown() }
        phase = .startingSession

        let selector = AutoDeviceSelector(wearables: wearables)
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: selector)
        } catch {
            throw GlassesError.sessionFailed(error.localizedDescription)
        }
        self.session = session

        try session.start()
        try await waitForSessionStarted(session)

        phase = .startingStream
        let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 24)
        guard let camera = try session.addCamera(config: config) else {
            throw GlassesError.sessionFailed("Session not ready for a camera.")
        }
        self.camera = camera

        let photoData = try await withStream(camera.stream)
        phase = .done
        return photoData
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

            Task { @MainActor in
                try? await Task.sleep(for: self.timeout)
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

    private func teardown() {
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
