import SwiftUI

/// Settings — availability status, Action Button setup, privacy (spec §5.4 / §5.6).
/// The availability card is real in increment 1; other controls arrive with their
/// features (dedupe threshold, categories, weekly insights, correction history).
struct SettingsView: View {
    @Environment(ModelAvailability.self) private var availability
    @AppStorage(ExtractionService.deliberateModeKey) private var deliberateMode = false

    var body: some View {
        NavigationStack {
            List {
                Section("On-device AI") {
                    availabilityCard
                }

                Section {
                    Toggle("Deliberate mode", isOn: $deliberateMode)
                } header: {
                    Text("Thinking")
                } footer: {
                    Text("Lets the AI reason a little longer before organizing — slower (~2×), but better at compound thoughts and tricky timing.")
                }

                Section("Action Button") {
                    Label {
                        Text("Settings → Action Button → Shortcut → **Offload · Quick Capture**")
                            .font(.Offload.body)
                    } icon: {
                        Image(systemName: "bolt.circle.fill")
                            .foregroundStyle(Color.Offload.indigo)
                    }
                    Text("The Quick Capture shortcut is also available in Shortcuts and Siri.")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                }

                Section("Privacy") {
                    Label("Everything stays on this iPhone by default.",
                          systemImage: "lock.fill")
                        .foregroundStyle(Color.Offload.text)
                }
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder
    private var availabilityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: availability.state.isAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(availability.state.isAvailable ? Color.Offload.teal : Color.Offload.amber)
                Text(availability.headline)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
            }
            if let fix = availability.fixAction {
                Text(fix)
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SettingsView().environment(ModelAvailability())
}
