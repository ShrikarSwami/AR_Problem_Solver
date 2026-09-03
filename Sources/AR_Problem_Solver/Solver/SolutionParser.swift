import Foundation

/// Turns Claude's raw reply into a `Solution`, relying on the output contract in
/// `ProblemSolverPrompt` (`PROBLEM:` line, `STEP n:` lines, trailing `DONE`).
/// Falls back gracefully when the model drifts from the format.
enum SolutionParser {
    /// Steps longer than this are soft-split so each teleprompter page fits the
    /// glasses viewport.
    static let maxStepCharacters = 240

    static func parse(_ raw: String) -> Solution {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.uppercased() != "DONE" }

        var problem = ""
        var rawSteps: [String] = []

        for line in lines {
            if problem.isEmpty, let value = capture(line, prefix: "PROBLEM:") {
                problem = value
            } else if let value = captureStep(line) {
                rawSteps.append(value)
            } else if !rawSteps.isEmpty {
                // Continuation of the previous step.
                rawSteps[rawSteps.count - 1] += " " + line
            } else if problem.isEmpty {
                problem = line
            }
        }

        // Fallback: no STEP lines at all — treat non-problem prose as one block.
        if rawSteps.isEmpty {
            let body = lines
                .filter { capture($0, prefix: "PROBLEM:") == nil }
                .joined(separator: " ")
            if !body.isEmpty { rawSteps = [body] }
        }

        let chunked = rawSteps.flatMap { softSplit($0, limit: maxStepCharacters) }
        let steps = chunked.enumerated().map { SolutionStep(number: $0.offset + 1, text: $0.element) }

        return Solution(
            problem: problem.isEmpty ? "Problem" : problem,
            steps: steps
        )
    }

    // MARK: - Line helpers

    private static func capture(_ line: String, prefix: String) -> String? {
        guard line.uppercased().hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Matches `STEP 3:` / `Step 3.` / `3)` / `3.` at the start of a line.
    private static func captureStep(_ line: String) -> String? {
        if let value = capture(line, prefix: "STEP") {
            // value looks like "3: do the thing" — strip the leading number + separator.
            return value.drop(while: { $0.isNumber || $0 == ":" || $0 == "." || $0 == ")" || $0 == " " })
                .trimmingCharacters(in: .whitespaces)
        }
        let pattern = #"^\s*(\d{1,2})[\.\)]\s+(.*)$"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(line[match])
        return matched.drop(while: { !($0 == " ") }).trimmingCharacters(in: .whitespaces)
    }

    /// Splits an over-long step on sentence boundaries, then hard-wraps whatever
    /// is still too long.
    static func softSplit(_ text: String, limit: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return [trimmed] }

        var chunks: [String] = []
        var current = ""
        for sentence in splitSentences(trimmed) {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= limit {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }

        return chunks.flatMap { $0.count > limit ? hardWrap($0, limit: limit) : [$0] }
    }

    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        for character in text {
            buffer.append(character)
            if character == "." || character == "!" || character == "?" {
                result.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer = ""
            }
        }
        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [text] : result
    }

    private static func hardWrap(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                chunks.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
