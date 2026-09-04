import Foundation
import Observation

/// Holds the current teleprompter position and re-sends the matching page to the
/// glasses whenever it changes. Button taps on the display (driven by the Neural
/// Wristband) call back into `next()` / `previous()` / `repeatCurrent()`.
@MainActor
@Observable
final class TeleprompterController {
    private(set) var solution: Solution
    private(set) var index: Int = 0

    private let sender: DisplaySending
    var onFinished: (@MainActor () async -> Void)?

    var currentStep: SolutionStep? {
        solution.steps.indices.contains(index) ? solution.steps[index] : nil
    }

    init(solution: Solution, sender: DisplaySending) {
        self.solution = solution
        self.sender = sender
    }

    /// Sends the first page.
    func start() async {
        index = 0
        await sendCurrent()
    }

    func next() async {
        if index >= solution.steps.count - 1 {
            // The last step's "Done" is the one real exit action — gate it with
            // an explicit confirm instead of finishing immediately.
            await sendExitConfirm()
            return
        }
        index += 1
        await sendCurrent()
    }

    /// What the exit-confirm screen's "Continue" button does: back out and
    /// re-show the step the wearer was on.
    func cancelExit() async {
        await sendCurrent()
    }

    /// What the exit-confirm screen's "Exit" button does: hand off to the
    /// coordinator's completion flow.
    func confirmExit() async {
        await onFinished?()
    }

    func previous() async {
        index = max(0, index - 1)
        await sendCurrent()
    }

    func repeatCurrent() async {
        await sendCurrent()
    }

    /// Shows the "Exit Problem Solver?" guard. Continue re-sends the current
    /// (last) step; Exit hands off to `onFinished`.
    private func sendExitConfirm() async {
        let page = TeleprompterDisplay.exitConfirm(
            onContinue: { [weak self] in Task { await self?.cancelExit() } },
            onExit: { [weak self] in Task { await self?.confirmExit() } }
        )
        do {
            try await sender.send(page)
        } catch {
            AppLog.display.error("Failed to send exit confirm: \(error.localizedDescription)")
        }
    }

    private func sendCurrent() async {
        guard let step = currentStep else { return }
        let page = TeleprompterDisplay.page(
            problem: solution.problem,
            step: step,
            count: solution.steps.count,
            onPrevious: { [weak self] in Task { await self?.previous() } },
            onNext: { [weak self] in Task { await self?.next() } },
            onRepeat: { [weak self] in Task { await self?.repeatCurrent() } }
        )
        do {
            try await sender.send(page)
        } catch {
            AppLog.display.error("Failed to send teleprompter page \(self.index): \(error.localizedDescription)")
        }
    }
}
