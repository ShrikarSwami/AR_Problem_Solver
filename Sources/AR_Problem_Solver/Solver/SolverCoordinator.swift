import Foundation
import Observation

/// Orchestrates one problem-solving run:
/// capture photo → send to Claude → parse into steps → drive the teleprompter.
@MainActor
@Observable
final class SolverCoordinator {
    enum State: Equatable {
        case idle
        case capturing
        case thinking
        case presenting(Solution)
        case failed(String)

        var isBusy: Bool { self == .capturing || self == .thinking }
    }

    private(set) var state: State = .idle
    private(set) var teleprompter: TeleprompterController?

    private let camera: PhotoCapturing
    private let solver: ProblemSolving
    private let display: DisplaySending
    /// Whether a registered device is available. Injected so the coordinator can
    /// fail fast without reaching into `WearablesService`.
    private let isDeviceReady: @MainActor () -> Bool
    /// Pause between closing one DAT session and opening the next, so the
    /// Bluetooth link settles. Overridable for tests.
    var handoffDelay: Duration = .milliseconds(600)

    /// Fired only after the wearer explicitly exits Problem Solver Mode (finish's
    /// "Exit" choice, or the phone's "End session"), so the app can re-send the
    /// glasses home screen. NOT fired between solves — `finish()` waits on the
    /// glasses for "Scan Next" vs "Exit" rather than auto-returning to idle.
    var onIdle: (@MainActor () async -> Void)?

    init(
        camera: PhotoCapturing,
        solver: ProblemSolving,
        display: DisplaySending,
        isDeviceReady: @escaping @MainActor () -> Bool = { true }
    ) {
        self.camera = camera
        self.solver = solver
        self.display = display
        self.isDeviceReady = isDeviceReady
    }

    /// Full run. Safe to call again after it finishes or fails.
    func solve() async {
        guard !state.isBusy else { return }
        guard isDeviceReady() else {
            state = .failed(GlassesError.notAuthorized.localizedDescription)
            return
        }
        teleprompter = nil

        do {
            // DAT allows one DeviceSession per device, so release the home-screen
            // display session before the camera opens its own.
            display.end()
            try? await Task.sleep(for: handoffDelay)

            state = .capturing
            let jpeg = try await camera.capturePhoto()
            AppLog.solver.info("Captured \(jpeg.count) byte photo")

            state = .thinking
            try? await Task.sleep(for: handoffDelay)
            try? await display.send(TeleprompterDisplay.thinking(problem: "Reading the problem…"))

            let raw = try await solver.solve(imageJPEG: jpeg)
            let solution = SolutionParser.parse(raw)
            guard !solution.isEmpty else {
                throw ClaudeError.emptyResponse
            }
            AppLog.solver.info("Parsed \(solution.steps.count) steps")

            let controller = TeleprompterController(solution: solution, sender: display)
            controller.onFinished = { [weak self] in await self?.finish() }
            teleprompter = controller
            state = .presenting(solution)
            await controller.start()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.solver.error("solve() failed: \(message)")
            state = .failed(message)
            try? await display.send(
                TeleprompterDisplay.failure(message) { [weak self] in
                    Task { @MainActor in await self?.solve() }
                }
            )
        }
    }

    /// Called once the wearer confirms "Exit" on the last step. Problem Solver
    /// Mode stays live — the glasses show a completion card with "Scan Next"
    /// (loops straight back into `solve()`) and "Exit" (the only path back to
    /// the home screen). Nothing auto-dismisses.
    func finish() async {
        teleprompter = nil
        state = .idle
        try? await display.send(
            TeleprompterDisplay.completed(
                onScanNext: { [weak self] in Task { @MainActor in await self?.scanNext() } },
                onExit: { [weak self] in Task { @MainActor in await self?.exitToHome() } }
            )
        )
    }

    /// What the completion card's "Scan Next" button does: loop straight back
    /// into another solve without leaving Problem Solver Mode.
    func scanNext() async {
        await solve()
    }

    /// What the completion card's "Exit" button does (also used by the phone's
    /// "End session"): closes the display session and hands back to the app's
    /// idle/home screen.
    func exitToHome() async {
        display.end()
        try? await Task.sleep(for: handoffDelay)
        await onIdle?()
    }

    /// Hard exit from the phone (the "End session" button) — leaves Problem
    /// Solver Mode regardless of what the glasses are currently showing.
    func reset() async {
        teleprompter = nil
        state = .idle
        await exitToHome()
    }
}
