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
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ClaudeAPI.version, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, status) = try await sendWithRetry(request)

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

    /// Verifies the API key and network path with a `GET /v1/models` call, which
    /// Anthropic does not bill as token usage. Never throws — returns a
    /// `ClaudeConnection` describing what happened.
    func checkConnection() async -> ClaudeConnection {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { return .missingKey }

        var request = URLRequest(url: ClaudeAPI.modelsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ClaudeAPI.version, forHTTPHeaderField: "anthropic-version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable(error.localizedDescription)
        }

        switch (response as? HTTPURLResponse)?.statusCode ?? -1 {
        case 200:
            let count = (try? JSONDecoder().decode(ClaudeModelsResponse.self, from: data))?.data.count ?? 0
            AppLog.claude.info("Claude connection OK (\(count) models)")
            return .ok(models: count)
        case 401, 403:
            return .unauthorized
        case let other:
            return .unexpected(status: other)
        }
    }

    /// Sends the request, retrying once on a transient status (429 / 5xx) after a
    /// short backoff that honours `retry-after` when present.
    private func sendWithRetry(_ request: URLRequest, attempt: Int = 0) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeError.transport(error)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1

        let transient = status == 429 || (500..<600).contains(status)
        guard transient, attempt < 1 else { return (data, status) }

        let retryAfter = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 1.5
        AppLog.claude.notice("Claude \(status); retrying in \(retryAfter, format: .fixed(precision: 1))s")
        try? await Task.sleep(for: .seconds(min(retryAfter, 10)))
        return try await sendWithRetry(request, attempt: attempt + 1)
    }
}

private func nonEmpty(_ string: String) -> String? {
    string.isEmpty ? nil : string
}
