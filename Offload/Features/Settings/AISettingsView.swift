import SwiftUI

/// Where the user connects Gemini and controls the on-device/cloud balance.
struct AISettingsView: View {
    @AppStorage(AIRouter.onDeviceOnlyKey) private var onDeviceOnly = false

    @State private var key = ""
    @State private var savedKey = false
    @State private var usedToday = 0
    @State private var testing = false
    @State private var testResult: String?
    @State private var showKey = false

    var body: some View {
        Form {
            Section {
                if savedKey && !showKey {
                    HStack {
                        Label("Key connected", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.Offload.teal)
                        Spacer()
                        Button("Change") { showKey = true; key = "" }
                            .font(.caption)
                    }
                } else {
                    SecureField("Paste your Gemini API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Save") { save() }
                            .disabled(key.trimmingCharacters(in: .whitespaces).count < 10)
                        Spacer()
                        if savedKey {
                            Button("Remove", role: .destructive) { remove() }
                                .font(.caption)
                        }
                    }
                }
            } header: {
                Text("Gemini")
            } footer: {
                Text("Get a free key at aistudio.google.com → “Get API key”. It's stored only in your device Keychain and used to make Offload's AI far smarter than the on-device model — extraction, planning, insights.")
            }

            if savedKey {
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("Test connection", systemImage: "bolt.horizontal.circle")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult)
                            .font(.Offload.data)
                            .foregroundStyle(testResult.hasPrefix("Connected") ? Color.Offload.teal : Color.Offload.amber)
                    }
                    HStack {
                        Text("Used today")
                        Spacer()
                        Text("\(usedToday) / \(AIBudget.maxPerDay)")
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                    }
                } footer: {
                    Text("Free tier: about 15 requests a minute and \(AIBudget.maxPerDay) a day. When you hit a limit, Offload quietly uses the on-device model until it resets.")
                }
            }

            Section {
                Toggle("Stay on-device (private mode)", isOn: $onDeviceOnly)
            } footer: {
                Text("When on, nothing is ever sent to Gemini — the app uses Apple's on-device model for everything. Turn this on for anything sensitive, like clinical notes. Off by default so the app is as smart as possible.")
            }
        }
        .navigationTitle("Intelligence")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            savedKey = SecretStore.hasGeminiKey
            usedToday = await AIRouter.shared.usedToday()
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecretStore.geminiKey = trimmed
        savedKey = SecretStore.hasGeminiKey
        showKey = false
        key = ""
        Haptics.success()
    }

    private func remove() {
        SecretStore.geminiKey = nil
        savedKey = false
        testResult = nil
        Haptics.light()
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        // Call Gemini directly (not via the fallback path) so this genuinely tests the cloud.
        guard let apiKey = SecretStore.geminiKey else { testResult = "No key saved."; return }
        do {
            _ = try await GeminiClient(apiKey: apiKey).generateText(
                system: "Reply with exactly: ok", prompt: "ok", temperature: 0)
            testResult = "Connected — Gemini responded."
            Haptics.success()
        } catch {
            testResult = "Failed: \(error.localizedDescription)"
        }
    }
}
