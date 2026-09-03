import Foundation

/// Seam for `SolverCoordinator`: turns a JPEG into solution text.
protocol ProblemSolving: Sendable {
    /// - Parameter imageJPEG: raw JPEG bytes of the captured problem.
    /// - Returns: the model's raw text reply (still to be parsed into steps).
    func solve(imageJPEG: Data) async throws -> String
}

/// Calls the Anthropic Messages API with the captured photo + problem-solver
/// system prompt. Non-streaming.
struct ClaudeClient: ProblemSolving {
    var model: String = ClaudeAPI.defaultModel
    var session: URLSession = .shared
    /// Resolves the API key at call time: Keychain (in-app) first, then the
    /// build-time value from `Secrets.xcconfig`.
    var apiKeyProvider: @Sendable () -> String? = {
        KeychainStore.readAPIKey() ?? nonEmpty(Secrets.anthropicAPIKey)
    }

    func solve(imageJPEG: Data) async throws -> String {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }

        let body = ClaudeRequest(
            model: model,
            maxTokens: ClaudeAPI.maxTokens,
            system: ProblemSolverPrompt.system,
            messages: [
                .init(role: "user", content: [
                    .imageBase64(mediaType: "image/jpeg", data: imageJPEG.base64EncodedString()),
                    .text(ProblemSolverPrompt.userInstruction),
                ]),
            ]
        )

        var request = URLRequest(url: ClaudeAPI.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ClaudeAPI.version, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ClaudeAPIError.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw ClaudeError.http(status: status, message: message)
        }

        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeError.emptyResponse }
        AppLog.claude.info("Claude reply received (\(text.count) chars, stop=\(decoded.stopReason ?? "nil"))")
        return text
    }
}

private func nonEmpty(_ string: String) -> String? {
    string.isEmpty ? nil : string
}
