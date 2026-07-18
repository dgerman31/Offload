import SwiftUI

/// Home — contextual groups + recent captures (spec §5.4). Increment 1 shows the
/// empty state (an invitation to capture) and the in-app capture button that mirrors
/// the Action Button. Real contextual groups arrive once the data layer lands.
struct HomeView: View {
    @Environment(CaptureCoordinator.self) private var capture

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    EmptyCaptureInvitation { capture.beginCapture() }
                        .padding(.top, 60)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .background(Color.Offload.background)
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        capture.beginCapture()
                    } label: {
                        Image(systemName: "bolt.circle.fill")
                            .font(.title2)
                    }
                    .accessibilityLabel("Quick Capture")
                }
            }
        }
    }
}

/// Reusable empty-state used across tabs — an invitation, not decoration (spec §5.6).
struct EmptyCaptureInvitation: View {
    var onCapture: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.Offload.indigo)
            Text("Nothing to organize yet")
                .font(.Offload.section)
                .foregroundStyle(Color.Offload.text)
            Text("Press the Action Button — or tap below — and just say what's on your mind. Offload sorts it out.")
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.muted)
                .multilineTextAlignment(.center)
            Button(action: onCapture) {
                Label("Capture a thought", systemImage: "mic.fill")
                    .font(.Offload.taskTitle)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.Offload.indigo, in: .capsule)
                    .foregroundStyle(.white)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 360)
    }
}

#Preview {
    HomeView().environment(CaptureCoordinator.shared)
}
