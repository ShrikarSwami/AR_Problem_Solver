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
            .filter { !$0.isEmpty && !isTerminator($0) }

        var problem = ""
        var rawSteps: [String] = []

        for line in lines {
            if problem.isEmpty, let value = capture(line, prefix: "PROBLEM:") {
                problem = value
            } else if let value = captureStep(line) {
                if !value.isEmpty { rawSteps.append(value) }
            } else if let last = rawSteps.last, !endsSentence(last) {
                // A hard-wrapped continuation of the previous step — only when the
                // previous line didn't already end on sentence punctuation. This
                // rejoins wrapped steps while dropping stray sign-off lines.
                rawSteps[rawSteps.count - 1] = last + " " + line
            } else if rawSteps.isEmpty, problem.isEmpty {
                problem = line
            }
            // else: trailing prose after a complete step — ignore.
        }

        // Fallback: no STEP lines at all — treat non-problem prose as one block.
        if rawSteps.isEmpty {
            let body = lines
                .filter { capture($0, prefix: "PROBLEM:") == nil }
                .joined(separator: " ")
            if !body.isEmpty { rawSteps = [body] }
        }

        let steps = rawSteps
            .flatMap { softSplit($0, limit: maxStepCharacters) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { SolutionStep(number: $0.offset + 1, text: $0.element) }

        return Solution(
            problem: problem.isEmpty ? "Problem" : problem,
            steps: steps
        )
    }

    // MARK: - Line helpers

    private static func isTerminator(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper == "DONE" || upper == "DONE." || upper == "END"
    }

    private static func capture(_ line: String, prefix: String) -> String? {
        guard line.uppercased().hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Matches `STEP 3: text` / `Step 3. text` / `3) text` / `3. text` / `3 - text`
    /// at the start of a line and returns just the step text.
    private static func captureStep(_ line: String) -> String? {
        let leadingSeparators = Set<Character>([":", ".", ")", "-", "–", "—", " "])
        if let value = capture(line, prefix: "STEP"), value.first?.isNumber == true {
            // value looks like "3: do the thing" — drop the digits then the
            // separator run, but only from the front (keep trailing punctuation).
            let afterDigits = value.drop { $0.isNumber }
            return String(afterDigits.drop { leadingSeparators.contains($0) })
                .trimmingCharacters(in: .whitespaces)
        }
        // Bare "3. text" / "3) text" / "3 - text" (1–2 digit index).
        let pattern = #"^\s*(\d{1,2})\s*[\.\):\-–—]\s+(.+)$"#
        guard let match = line.range(of: pattern, options: .regularExpression),
              String(line[match]).range(of: #"^\s*\d{1,2}\s*[\.\):\-–—]\s+"#, options: .regularExpression) != nil
        else { return nil }
        // Strip the leading "<n><sep> " prefix.
        let stripped = line.replacingOccurrences(
            of: #"^\s*\d{1,2}\s*[\.\):\-–—]\s+"#,
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a step string ends on terminal punctuation (so the next line is a
    /// new thought, not a wrap continuation).
    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        return ".!?:".contains(last)
    }

    /// Splits an over-long step on sentence boundaries, then hard-wraps whatever
    /// is still too long. Decimal points (`3.14`) and the dots in short
    /// abbreviations are not treated as sentence ends.
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
        let chars = Array(text)
        for (index, character) in chars.enumerated() {
            buffer.append(character)
            guard character == "." || character == "!" || character == "?" else { continue }

            // Not a sentence end if it sits between digits (e.g. "3.14").
            let prev = index > 0 ? chars[index - 1] : " "
            let next = index + 1 < chars.count ? chars[index + 1] : " "
            if character == ".", prev.isNumber, next.isNumber || next == " " && isMidNumber(chars, index) {
                continue
            }
            // A sentence end is followed by whitespace/end.
            if next == " " || index + 1 == chars.count {
                result.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer = ""
            }
        }
        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [text] : result
    }

    /// Heuristic: the `.` at `index` is inside a number like "3.14" even though the
    /// next visible char is a space (guards "= 3." followed by " 14" style OCR).
    private static func isMidNumber(_ chars: [Character], _ index: Int) -> Bool {
        guard index > 0, chars[index - 1].isNumber else { return false }
        var j = index + 1
        while j < chars.count, chars[j] == " " { j += 1 }
        return j < chars.count && chars[j].isNumber
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
