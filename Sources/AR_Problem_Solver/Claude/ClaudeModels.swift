import Foundation

/// Wire types for the Anthropic Messages API (`POST /v1/messages`).
/// Only the subset this app needs is modeled.
enum ClaudeAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let version = "2023-06-01"
    static let defaultModel = "claude-sonnet-5"
    static let maxTokens = 1024
}

struct ClaudeRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }

    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    enum Content: Encodable {
        case text(String)
        case imageBase64(mediaType: String, data: String)

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let value):
                try c.encode("text", forKey: .type)
                try c.encode(value, forKey: .text)
            case .imageBase64(let mediaType, let data):
                try c.encode("image", forKey: .type)
                var source = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode(mediaType, forKey: .mediaType)
                try source.encode(data, forKey: .data)
            }
        }

        private enum CodingKeys: String, CodingKey { case type, text, source }
        private enum SourceKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }
    }
}

struct ClaudeResponse: Decodable {
    let content: [Block]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }

    struct Block: Decodable {
        let type: String
        let text: String?
    }

    /// Concatenated text of all `text` blocks.
    var text: String {
        content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }
}

struct ClaudeAPIError: Decodable {
    struct Detail: Decodable {
        let type: String
        let message: String
    }
    let error: Detail
}

enum ClaudeError: LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case emptyResponse
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Claude API key. Add one in Settings."
        case .http(let status, let message):
            return "Claude API error (\(status)): \(message)"
        case .emptyResponse:
            return "Claude returned an empty response."
        case .transport(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
