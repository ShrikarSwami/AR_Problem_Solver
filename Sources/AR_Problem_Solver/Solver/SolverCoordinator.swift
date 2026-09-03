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

    init(camera: PhotoCapturing, solver: ProblemSolving, display: DisplaySending) {
        self.camera = camera
        self.solver = solver
        self.display = display
    }

    /// Full run. Safe to call again after it finishes or fails.
    func solve() async {
        guard !state.isBusy else { return }
        teleprompter = nil

        do {
            state = .capturing
            let jpeg = try await camera.capturePhoto()
            AppLog.solver.info("Captured \(jpeg.count) byte photo")

            state = .thinking
            try? await display.send(TeleprompterDisplay.thinking(problem: "Reading the problem…"))

            let raw = try await solver.solve(imageJPEG: jpeg)
            let solution = SolutionParser.parse(raw)
            guard !solution.isEmpty else {
                throw ClaudeError.emptyResponse
            }

            let controller = TeleprompterController(solution: solution, sender: display)
            controller.onFinished = { [weak self] in self?.finish() }
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

    /// Called when the wearer taps "Done" on the last step.
    func finish() {
        display.end()
        teleprompter = nil
        state = .idle
    }

    func reset() {
        display.end()
        teleprompter = nil
        state = .idle
    }
}
