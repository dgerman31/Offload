import SwiftUI

/// Connecting Offload to the Anki add-on, and proving it worked.
struct AnkiBridgeSettingsView: View {
    @State private var bridge = AnkiBridge.shared
    @State private var gistID = AnkiBridge.shared.gistID
    @State private var token = ""
    @State private var checking = false
    @State private var confirmingDisconnect = false
    @State private var now = Date()

    private var hasToken: Bool { bridge.token != nil }

    var body: some View {
        Form {
            Section {
                Toggle("Read my Anki progress", isOn: Binding(
                    get: { bridge.isEnabled },
                    set: { bridge.isEnabled = $0 }
                ))
                Toggle("Show it on the Lock Screen", isOn: Binding(
                    get: { bridge.showsLiveActivity },
                    set: { on in
                        bridge.showsLiveActivity = on
                        Task { await AnkiLiveActivity.sync(bridge.current(), enabled: on, canStart: true) }
                    }
                ))
                .disabled(!bridge.isEnabled)
            } footer: {
                Text("A bar on Home and on your Lock Screen showing what's left of today's due cards, and a warning when a heavy day is coming. It disappears when you're done.")
            }

            if let snapshot = bridge.snapshot {
                Section("Last snapshot") {
                    row("Deck", snapshot.deck)
                    row("Done today", "\(snapshot.today.reviewsDone) reviews · \(snapshot.today.newDone) new")
                    row("Still due", "\(snapshot.dueRemaining)")
                    row("Updated", snapshot.freshnessLabel(now: now) ?? "Just now")
                    if snapshot.isExpired(now: now) {
                        Label("This is yesterday's — Anki's day has rolled over.", systemImage: "clock.badge.exclamationmark")
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.amber)
                    }
                }
            }

            Section {
                TextField("Gist id", text: $gistID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                SecureField(hasToken ? "Token saved — paste to replace" : "GitHub token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                }
                .disabled(gistID.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Connection")
            } footer: {
                Text("The token is stored in the Keychain, never in a file, and is only ever sent to GitHub. It needs Gists read and write and nothing else.")
            }

            Section {
                Button {
                    checking = true
                    Task {
                        await bridge.refresh(force: true)
                        await AnkiLiveActivity.sync(bridge.current(), enabled: bridge.showsLiveActivity, canStart: true)
                        now = Date()
                        checking = false
                    }
                } label: {
                    HStack {
                        Label("Check now", systemImage: "arrow.clockwise")
                        if checking { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!bridge.isConfigured || checking)

                if let error = bridge.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text(bridge.isConfigured
                     ? "Offload also checks whenever you open it, and about every minute while you're looking at Home."
                     : "Add the gist id and token above first.")
            }

            Section {
                setup(1, "In Anki: **Tools → Add-ons → View Files**, drop the `offload_anki` folder in, restart Anki.")
                setup(2, "**Tools → Add-ons → offload_anki → Config**: set your deck name, gist id and token.")
                setup(3, "**Tools → “Offload: push Anki progress now”** — it should tell you what it found.")
                setup(4, "Paste the same gist id and a token above, then **Check now**.")
            } header: {
                Text("Setting it up")
            } footer: {
                Text("The add-on runs on Anki Desktop. If you review on your phone, the numbers arrive once AnkiMobile has synced to AnkiWeb and the desktop has synced down — leaving Anki open on the Mac makes that automatic.")
            }

            if bridge.isConfigured {
                Section {
                    Button(role: .destructive) { confirmingDisconnect = true } label: {
                        Label("Disconnect", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Anki")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect Anki?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                bridge.disconnect()
                gistID = ""
                token = ""
                Task { await AnkiLiveActivity.end() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Forgets the token and the last snapshot. The add-on keeps running until you remove it in Anki.")
        }
    }

    private func save() {
        bridge.gistID = gistID
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            bridge.token = trimmed
            token = ""   // never leave a token sitting in view state
        }
        Haptics.success()
        Task {
            await bridge.refresh(force: true)
            await AnkiLiveActivity.sync(bridge.current(), enabled: bridge.showsLiveActivity, canStart: true)
            now = Date()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.Offload.muted)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Color.Offload.text).multilineTextAlignment(.trailing)
        }
        .font(.Offload.body)
    }

    private func setup(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.system(.caption, design: .rounded)).fontWeight(.bold)
                .frame(width: 22, height: 22)
                .background(Color.Offload.teal.opacity(0.18), in: .circle)
                .foregroundStyle(Color.Offload.teal)
            Text(.init(text))
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
