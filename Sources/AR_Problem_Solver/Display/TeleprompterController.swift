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
            await onFinished?()
            return
        }
        index += 1
        await sendCurrent()
    }

    func previous() async {
        index = max(0, index - 1)
        await sendCurrent()
    }

    func repeatCurrent() async {
        await sendCurrent()
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
