import Foundation

/// `TalkieBridge` is the ONLY networked module in Talkie. It is compiled into the
/// app only in an opt-in "connected" build flavor, and even then is off by default
/// behind explicit user consent + a Keychain-stored key. The always-local core
/// (the `Talkie` app target and `talkie-mcp`) never imports this module — that
/// separation is what keeps the zero-network promise structural (feature 18 / 15).
///
/// It defines its own minimal seam (it can't import the app target); the app
/// adapts `ClaudeBridge` to its `Summarizer` protocol at the composition root.
public protocol BridgeSummarizer: Sendable {
    func generate(instructions: String, input: String) async throws -> String?
}

public enum ClaudeBridgeError: Error, LocalizedError {
    case missingKey
    case http(Int, String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "No Anthropic API key configured."
        case .http(let code, let body): return "Claude API error \(code): \(body)"
        case .malformedResponse: return "Unexpected response from the Claude API."
        }
    }
}

/// Calls the Anthropic Messages API for the heavy lifts the on-device model can't
/// do as well (long-meeting summaries, agentic drafting, richer graph Q&A). Opt-in.
public struct ClaudeBridge: BridgeSummarizer {
    public var apiKey: String
    /// Defaults to a fast, capable current model; configurable per call site.
    public var model: String
    public var maxTokens: Int

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"

    public init(apiKey: String, model: String = "claude-sonnet-4-6", maxTokens: Int = 1024) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
    }

    public func generate(instructions: String, input: String) async throws -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !apiKey.isEmpty else { throw ClaudeBridgeError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": instructions,
            "messages": [["role": "user", "content": trimmed]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeBridgeError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeBridgeError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw ClaudeBridgeError.malformedResponse
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
