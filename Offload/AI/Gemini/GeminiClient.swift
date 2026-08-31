import Foundation
import OSLog

/// A description of the JSON shape we ask Gemini to return. Gemini enforces this during
/// generation (a constrained-decoding "responseSchema"), so — like Apple's `@Generable` — we
/// get back valid, typed JSON rather than free text to wrangle.
indirect enum GSchema: Sendable {
    case string(nullable: Bool = false, enumValues: [String]? = nil)
    case integer(nullable: Bool = false)
    /// A floating-point value. Distinct from `.integer` because Gemini's schema subset types them
    /// separately, and asking for an INTEGER confidence would quantise it to 0 or 1.
    case number(nullable: Bool = false)
    case boolean
    case array(GSchema)
    /// Ordered properties (Gemini honours `propertyOrdering`) with the required subset.
    case object(properties: [Property], required: [String])

    /// A named sub-schema. A concrete struct rather than a tuple so `Sendable` is unambiguous.
    struct Property: Sendable {
        var name: String
        var schema: GSchema
        init(_ name: String, _ schema: GSchema) { self.name = name; self.schema = schema }
    }

    /// Encode to Gemini's OpenAPI-subset schema format as a plain JSON object.
    var json: [String: Any] {
        switch self {
        case let .string(nullable, enumValues):
            var s: [String: Any] = ["type": "STRING"]
            if nullable { s["nullable"] = true }
            if let enumValues { s["enum"] = enumValues; s["format"] = "enum" }
            return s
        case let .integer(nullable):
            var s: [String: Any] = ["type": "INTEGER"]
            if nullable { s["nullable"] = true }
            return s
        case let .number(nullable):
            var s: [String: Any] = ["type": "NUMBER"]
            if nullable { s["nullable"] = true }
            return s
        case .boolean:
            return ["type": "BOOLEAN"]
        case let .array(items):
            return ["type": "ARRAY", "items": items.json]
        case let .object(properties, required):
            var props: [String: Any] = [:]
            for property in properties { props[property.name] = property.schema.json }
            var s: [String: Any] = [
                "type": "OBJECT",
                "properties": props,
                "propertyOrdering": properties.map(\.name)
            ]
            if !required.isEmpty { s["required"] = required }
            return s
        }
    }
}

enum GeminiError: Error, LocalizedError {
    case noKey
    /// `retryAfter` is the `Retry-After` header in seconds, when the response carried one — nil
    /// otherwise (Google doesn't document sending one for `generateContent`, so this is a courtesy
    /// read, not a guarantee).
    case http(status: Int, message: String, retryAfter: TimeInterval?)
    case blocked
    case emptyResponse
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey:                    return "No Gemini API key set."
        case let .http(status, msg, _): return "Gemini HTTP \(status): \(msg)"
        case .blocked:                  return "Gemini blocked the response (safety)."
        case .emptyResponse:            return "Gemini returned nothing."
        case .badResponse:              return "Couldn't read Gemini's response."
        }
    }
}

/// Thin async wrapper over the Gemini `generateContent` REST endpoint. Stateless and value-typed
/// so it composes freely; the higher layers add routing, budgeting and fallback.
struct GeminiClient: Sendable {
    var apiKey: String
    /// The model the user asked for; kept as a constant that's trivial to bump.
    var model: String = GeminiClient.defaultModel
    /// Per-request timeout, handed to `URLRequest(url:timeoutInterval:)`.
    ///
    /// Defaults to the *interactive* shape — capture extraction, where the user is watching a
    /// spinner and every second here is a second added before we can fall back to the on-device
    /// model. 12s is short enough that a genuinely stuck connection still hands off to Apple
    /// Intelligence while the moment is fresh. A caller doing background/day-planning work, which
    /// nobody is staring at and which can reasonably wait for a better answer, should set this
    /// higher on its own instance before calling — it's a plain `var` for exactly that reason.
    var timeout: TimeInterval = 12

    static let defaultModel = "gemini-3.5-flash-lite"

    private var endpoint: URL? {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
    }

    /// One `URLSession` for every `GeminiClient` value, rather than `URLSession.shared` (which
    /// can't be configured at all) or a fresh session per call (which would throw away connection
    /// reuse and, worse, give every call site its own copy of these settings to get right).
    /// `waitsForConnectivity` is Apple's recommended offline strategy: attempt the request and let
    /// the system hold it until connectivity returns, rather than a preflight `NWPathMonitor`
    /// reachability check — Apple's own guidance is explicit that reachability checks are
    /// unreliable (both false positives and false negatives) and that waiting on the request
    /// itself is the correct pattern.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    /// Structured call: returns the model's JSON payload decoded into `T`.
    func generate<T: Decodable & Sendable>(
        system: String,
        prompt: String,
        schema: GSchema,
        as type: T.Type,
        temperature: Double = 0.2
    ) async throws -> T {
        let config: [String: Any] = [
            "temperature": temperature,
            "responseMimeType": "application/json",
            "responseSchema": schema.json
        ]
        let text = try await run(system: system, prompt: prompt, generationConfig: config)
        guard let data = text.data(using: .utf8) else { throw GeminiError.badResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Freeform call: returns the model's text (for reflections, briefs).
    func generateText(system: String, prompt: String, temperature: Double = 0.4) async throws -> String {
        try await run(system: system, prompt: prompt,
                      generationConfig: ["temperature": temperature]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Transport

    private func run(system: String, prompt: String, generationConfig: [String: Any]) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiError.noKey }
        guard let endpoint else { throw GeminiError.badResponse }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": generationConfig
        ]

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The key rides in a header rather than the URL, so it can't land in logs or caches.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await Self.send(request)
    }

    /// Send `request`, retrying transient failures with capped, jittered backoff and giving up
    /// immediately on anything `RetryPolicy` says is a bug or a cancellation. Never logs the
    /// request or response bodies — only shapes: status codes, error kinds, attempt counts, and
    /// durations, which is what actually helps diagnose a bad key or a flaky connection without
    /// putting a user's captured text in the unified log.
    private static func send(_ request: URLRequest) async throws -> String {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            let started = Date()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
                guard (200..<300).contains(http.statusCode) else {
                    throw GeminiError.http(status: http.statusCode, message: errorMessage(from: data),
                                            retryAfter: retryAfterSeconds(http))
                }
                let text = try extractText(from: data)
                Log.ai.debug("Gemini call OK: attempt \(attempt, privacy: .public), \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s")
                return text
            } catch {
                let elapsed = Date().timeIntervalSince(started)
                let classification = RetryPolicy.classify(error)
                let kind = errorKind(error)
                guard classification == .retryable, attempt < RetryPolicy.maxAttempts else {
                    switch classification {
                    case .cancelled:
                        break // Not a failure — nothing to log.
                    case .retryable:
                        Log.ai.error("Gemini call exhausted retries: attempt \(attempt, privacy: .public)/\(RetryPolicy.maxAttempts, privacy: .public), kind \(kind, privacy: .public), \(elapsed, format: .fixed(precision: 2), privacy: .public)s")
                    case .terminal:
                        // "Log loudly" — this is a bug in what we sent (bad schema, wrong
                        // model/endpoint), not a network condition, so it's worth a `.fault`.
                        Log.ai.fault("Gemini call failed (bug, not retrying): attempt \(attempt, privacy: .public), kind \(kind, privacy: .public)")
                    case .needsUserAction:
                        Log.ai.error("Gemini call rejected — needs user action (key?): attempt \(attempt, privacy: .public), kind \(kind, privacy: .public)")
                    }
                    throw error
                }
                // A server-supplied `Retry-After` beats our own guess when we have one; otherwise
                // fall back to jittered exponential backoff. Either way, cap it — a server asking
                // us to wait an hour is still bounded by how long this call is willing to hang.
                var delay = RetryPolicy.delay(attempt: attempt)
                if let gemini = error as? GeminiError, case let .http(_, _, retryAfter) = gemini,
                   let retryAfter {
                    delay = min(retryAfter, 60)
                }
                Log.ai.notice("Gemini call retrying: attempt \(attempt, privacy: .public) kind \(kind, privacy: .public) after \(elapsed, format: .fixed(precision: 2), privacy: .public)s, waiting \(delay, format: .fixed(precision: 2), privacy: .public)s")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// The `Retry-After` header, in seconds, when the response carries a numeric one. Google
    /// doesn't document sending one on `generateContent` errors, so this is read defensively —
    /// a missing or non-numeric header (e.g. an HTTP-date form) just means "use our own backoff".
    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(value.trimmingCharacters(in: .whitespaces))
    }

    /// A safe-to-log summary of an error: its HTTP status or `URLError` code, never the message
    /// text that rides along with it (Google's error `message` field, or any description that
    /// might echo request content, stays out of the log entirely).
    private static func errorKind(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError { return "URLError(\(urlError.code.rawValue))" }
        if let gemini = error as? GeminiError {
            switch gemini {
            case let .http(status, _, _): return "http(\(status))"
            case .noKey:               return "noKey"
            case .blocked:             return "blocked"
            case .emptyResponse:       return "emptyResponse"
            case .badResponse:         return "badResponse"
            }
        }
        return String(describing: type(of: error))
    }

    /// Pull the generated text out of the candidates envelope. Pure, so it's unit-testable
    /// without a network call.
    static func extractText(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.badResponse
        }
        if let feedback = root["promptFeedback"] as? [String: Any],
           feedback["blockReason"] != nil { throw GeminiError.blocked }
        guard let candidates = root["candidates"] as? [[String: Any]], let first = candidates.first
        else { throw GeminiError.emptyResponse }
        if (first["finishReason"] as? String) == "SAFETY" { throw GeminiError.blocked }
        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { throw GeminiError.emptyResponse }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw GeminiError.emptyResponse }
        return text
    }

    static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else { return "unknown" }
        return message
    }
}
