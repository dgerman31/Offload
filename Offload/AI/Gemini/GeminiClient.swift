import Foundation

/// A description of the JSON shape we ask Gemini to return. Gemini enforces this during
/// generation (a constrained-decoding "responseSchema"), so — like Apple's `@Generable` — we
/// get back valid, typed JSON rather than free text to wrangle.
indirect enum GSchema: Sendable {
    case string(nullable: Bool = false, enumValues: [String]? = nil)
    case integer(nullable: Bool = false)
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
    case http(status: Int, message: String)
    case blocked
    case emptyResponse
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey:                 return "No Gemini API key set."
        case let .http(status, msg): return "Gemini HTTP \(status): \(msg)"
        case .blocked:               return "Gemini blocked the response (safety)."
        case .emptyResponse:         return "Gemini returned nothing."
        case .badResponse:           return "Couldn't read Gemini's response."
        }
    }
}

/// Thin async wrapper over the Gemini `generateContent` REST endpoint. Stateless and value-typed
/// so it composes freely; the higher layers add routing, budgeting and fallback.
struct GeminiClient: Sendable {
    var apiKey: String
    /// The model the user asked for; kept as a constant that's trivial to bump.
    var model: String = GeminiClient.defaultModel
    var timeout: TimeInterval = 20

    static let defaultModel = "gemini-3.1-flash-lite"

    private var endpoint: URL? {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
    }

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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GeminiError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return try Self.extractText(from: data)
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
