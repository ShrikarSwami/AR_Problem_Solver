import Foundation

/// One page of the teleprompter flow.
struct SolutionStep: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// 1-based position as shown to the wearer.
    let number: Int
    let text: String

    static func == (lhs: SolutionStep, rhs: SolutionStep) -> Bool {
        lhs.number == rhs.number && lhs.text == rhs.text
    }
}

/// The full parsed result: a headline problem statement plus ordered steps.
struct Solution: Equatable, Sendable {
    let problem: String
    let steps: [SolutionStep]

    var isEmpty: Bool { steps.isEmpty }
}
