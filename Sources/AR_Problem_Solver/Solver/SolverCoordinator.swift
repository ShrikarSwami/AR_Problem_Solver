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
    /// Pause between camera-session teardown and opening the display session, so
    /// the Bluetooth link has a moment to settle. Overridable for tests.
    var handoffDelay: Duration = .milliseconds(600)
    /// How long the "all steps done" card stays up before the display session
    /// closes. Overridable for tests.
    var completionLinger: Duration = .seconds(2)

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
            state = .capturing
            let jpeg = try await camera.capturePhoto()
            AppLog.solver.info("Captured \(jpeg.count) byte photo")

            state = .thinking
            // Camera session has fully torn down inside capturePhoto(); let the
            // link settle before the display session opens.
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

    /// Called when the wearer taps "Done" on the last step: reset state now, show
    /// a brief confirmation card, then close the display session.
    func finish() async {
        teleprompter = nil
        state = .idle
        try? await display.send(TeleprompterDisplay.completed())
        try? await Task.sleep(for: completionLinger)
        display.end()
    }

    func reset() {
        display.end()
        teleprompter = nil
        state = .idle
    }
}
