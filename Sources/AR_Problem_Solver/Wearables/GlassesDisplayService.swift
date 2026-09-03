import Foundation
import Observation
import MWDATCore
import MWDATDisplay

/// Manages the display-session lifecycle: attach to a display-capable device,
/// send layouts, detach. Uses the sample's pending-action pattern so a `send`
/// issued before the display is ready is queued and flushed on `.started`.
@MainActor
@Observable
final class GlassesDisplayService: DisplaySending {
    private(set) var isConnected: Bool = false
    private(set) var isSending: Bool = false
    var lastError: String?

    private let wearables: WearablesInterface
    @ObservationIgnored private var deviceSelector: AutoDeviceSelector
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var stateToken: AnyListenerToken?
    @ObservationIgnored private var sessionStateTask: Task<Void, Never>?
    @ObservationIgnored private var sessionErrorTask: Task<Void, Never>?
    @ObservationIgnored private var displayStateTask: Task<Void, Never>?
    @ObservationIgnored private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
    @ObservationIgnored private var pendingAction: (() async -> Void)?

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
    }

    func send(_ page: FlexBox) async throws {
        if let display, isConnected {
            try await deliver(page, on: display)
            return
        }
        pendingAction = { [weak self] in
            guard let self, let display = self.display else { return }
            try? await self.deliver(page, on: display)
        }
        if display == nil {
            await attach()
        }
    }

    func end() {
        if let display {
            display.stop()
        } else {
            cancelTasks()
            session?.stop()
            session = nil
        }
    }

    // MARK: - Send

    private func deliver(_ page: FlexBox, on display: Display) async throws {
        isSending = true
        defer { isSending = false }
        do {
            try await display.send(page)
        } catch {
            let message = (error as? DisplayError)?.description ?? error.localizedDescription
            lastError = message
            throw error
        }
    }

    // MARK: - Attach / detach

    private func attach() async {
        guard display == nil else { return }
        do {
            let session = try wearables.createSession(deviceSelector: deviceSelector)
            self.session = session

            let stateStream = session.stateStream()
            let errorStream = session.errorStream()

            sessionStateTask = Task { [weak self] in
                for await state in stateStream {
                    guard let self else { return }
                    switch state {
                    case .started:
                        await self.setupDisplay(on: session)
                    case .stopping, .stopped:
                        self.isConnected = false
                        self.display = nil
                    default:
                        break
                    }
                }
            }
            sessionErrorTask = Task { [weak self] in
                for await error in errorStream {
                    self?.lastError = error.localizedDescription
                }
            }

            try session.start()
        } catch {
            lastError = "Failed to start display session: \(error.localizedDescription)"
        }
    }

    private func setupDisplay(on session: DeviceSession) async {
        guard display == nil else { return }
        do {
            let capability = try session.addDisplay()

            let (stream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
            displayStateContinuation = continuation
            stateToken = capability.statePublisher.listen { continuation.yield($0) }

            displayStateTask = Task { [weak self] in
                for await state in stream {
                    guard let self else { return }
                    switch state {
                    case .started:
                        self.isConnected = true
                        if let action = self.pendingAction {
                            self.pendingAction = nil
                            await action()
                        }
                    case .stopping:
                        self.isConnected = false
                    case .stopped:
                        self.teardownDisplay()
                    default:
                        break
                    }
                }
            }

            capability.start()
            display = capability
        } catch {
            lastError = "Failed to start display: \(error.localizedDescription)"
        }
    }

    private func teardownDisplay() {
        isConnected = false
        stateToken = nil
        displayStateContinuation?.finish()
        displayStateContinuation = nil
        display = nil
        cancelTasks()
        session?.stop()
        session = nil
    }

    private func cancelTasks() {
        sessionStateTask?.cancel(); sessionStateTask = nil
        sessionErrorTask?.cancel(); sessionErrorTask = nil
        displayStateTask?.cancel(); displayStateTask = nil
    }

    deinit {
        sessionStateTask?.cancel()
        sessionErrorTask?.cancel()
        displayStateTask?.cancel()
    }
}
