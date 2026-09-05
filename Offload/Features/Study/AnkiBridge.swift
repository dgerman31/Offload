import Foundation

/// Reads the deck snapshot the Anki add-on publishes, and keeps the last one it saw.
///
/// ### Why a gist
///
/// The obvious design is `AnkiConnect` over the LAN, and it's the wrong one: it works only while the
/// Mac is awake and on the same Wi-Fi, which is precisely not the case when you're out and want to
/// know whether you're on top of your cards. The add-on pushes to a secret gist instead — free, no
/// server to run, reachable anywhere. Counts only ever cross: no card content, no note text.
///
/// The token lives in the Keychain beside the Gemini key, never in `UserDefaults`.
@MainActor
@Observable
final class AnkiBridge {
    static let shared = AnkiBridge()

    /// The last snapshot fetched, restored on launch so the card draws immediately rather than
    /// flashing empty while the network wakes up.
    private(set) var snapshot: AnkiSnapshot?
    /// The last failure, in words worth showing. Nil once something succeeds.
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    nonisolated static let gistIDKey = "offload.anki.gistID"
    nonisolated static let enabledKey = "offload.anki.bridgeEnabled"
    nonisolated static let liveActivityKey = "offload.anki.liveActivity"
    private static let snapshotKey = "offload.anki.snapshot"
    nonisolated static let tokenAccount = "github.gistToken"
    private static let fileName = "offload-anki.json"

    private let defaults: UserDefaults
    /// Refreshes closer together than this are dropped: the card, the Live Activity and a
    /// background wake can all ask at once, and three identical requests help nobody.
    private static let minimumInterval: TimeInterval = 20
    private var lastRefresh = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.snapshotKey) {
            snapshot = try? JSONDecoder().decode(AnkiSnapshot.self, from: data)
        }
    }

    // MARK: Configuration

    var gistID: String {
        get { defaults.string(forKey: Self.gistIDKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.gistIDKey) }
    }

    var token: String? {
        get { SecretStore.get(account: Self.tokenAccount) }
        set { SecretStore.set(newValue, account: Self.tokenAccount) }
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var showsLiveActivity: Bool {
        get { defaults.object(forKey: Self.liveActivityKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.liveActivityKey) }
    }

    var isConfigured: Bool { !gistID.isEmpty && token != nil }

    /// The snapshot only if it still describes *today*. Past Anki's rollover the figures are a
    /// finished day's, and showing yesterday's progress bar as though it were live is worse than
    /// showing none.
    func current(now: Date = Date()) -> AnkiSnapshot? {
        guard isEnabled, let snapshot, !snapshot.isExpired(now: now) else { return nil }
        return snapshot
    }

    // MARK: Fetching

    enum BridgeError: LocalizedError {
        case notConfigured, badResponse(Int), missingFile, decodeFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured:  return "Add your gist id and a GitHub token first."
            case .badResponse(401), .badResponse(403):
                return "GitHub refused the token — check it has Gists read and write."
            case .badResponse(404):
                return "No gist with that id. Check it's the long hex id from the gist's URL."
            case .badResponse(let code): return "GitHub returned \(code)."
            case .missingFile:    return "The gist has no \(AnkiBridge.fileName) yet — run the add-on's push once."
            case .decodeFailed:   return "That file isn't a snapshot Offload understands."
            }
        }
    }

    @discardableResult
    func refresh(force: Bool = false, now: Date = Date()) async -> Bool {
        guard isEnabled, isConfigured else { return false }
        guard force || now.timeIntervalSince(lastRefresh) >= Self.minimumInterval else { return false }
        guard !isRefreshing else { return false }
        lastRefresh = now
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await fetch()
            snapshot = fetched
            lastError = nil
            if let data = try? JSONEncoder().encode(fetched) {
                defaults.set(data, forKey: Self.snapshotKey)
            }
            return true
        } catch {
            // Shape and reason only — a snapshot carries no user text, but the house rule is one
            // rule rather than one per call site.
            lastError = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach GitHub."
            Log.app.error("Anki bridge refresh failed: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    private func fetch() async throws -> AnkiSnapshot {
        guard let token, !gistID.isEmpty,
              let url = URL(string: "https://api.github.com/gists/\(gistID)")
        else { throw BridgeError.notConfigured }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub caches gist responses hard; without this the app can sit on a five-minute-old copy
        // while the add-on is pushing every minute, which reads as the bridge being broken.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BridgeError.badResponse(http.statusCode)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [String: Any],
              let file = files[Self.fileName] as? [String: Any]
        else { throw BridgeError.missingFile }

        // Tiny files come inline. A truncated one would need the raw URL, which shouldn't happen at
        // these sizes but is cheap to survive.
        let content: Data
        if let inline = file["content"] as? String, !(file["truncated"] as? Bool ?? false) {
            content = Data(inline.utf8)
        } else if let raw = file["raw_url"] as? String, let rawURL = URL(string: raw) {
            content = try await URLSession.shared.data(from: rawURL).0
        } else {
            throw BridgeError.missingFile
        }

        guard let decoded = try? JSONDecoder().decode(AnkiSnapshot.self, from: content) else {
            throw BridgeError.decodeFailed
        }
        return decoded
    }

    /// Forget everything, including the token. The escape hatch that makes the rest safe to turn on.
    func disconnect() {
        token = nil
        gistID = ""
        snapshot = nil
        lastError = nil
        defaults.removeObject(forKey: Self.snapshotKey)
    }
}
