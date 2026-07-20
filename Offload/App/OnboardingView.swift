import SwiftUI
import EventKit

/// First run. Three jobs: explain what this app actually is, get the Action Button set up
/// (without which the whole premise falls apart), and ask for permissions *in context* rather
/// than ambushing someone mid-capture with three system dialogs.
///
/// Every page is skippable — permissions are requested honestly, with what they're for stated
/// plainly, and the app degrades gracefully if they're refused.
struct OnboardingView: View {
    static let completedKey = "offload.onboarding.completed"

    @AppStorage(OnboardingView.completedKey) private var completed = false
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(NotificationService.remindersEnabledKey) private var remindersEnabled = false

    @State private var page = 0
    @State private var micGranted = false
    @State private var calendarGranted = false
    @State private var notificationsGranted = false

    private let pageCount = 4

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x141735), Color(hex: 0x3A2E7A)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcomePage.tag(0)
                    actionButtonPage.tag(1)
                    permissionsPage.tag(2)
                    appearancePage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots
                controls
            }
        }
    }

    // MARK: Pages

    private var welcomePage: some View {
        page(
            icon: "bolt.circle.fill",
            title: "Say it once.\nForget it safely.",
            body: "Press a button, speak a passing thought, and Offload turns it into organized tasks — on this iPhone, using Apple's on-device AI. Nothing is sent anywhere."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                bullet("mic.fill", "Speak or type — it understands what you meant, not just what you said")
                bullet("calendar", "Merges with your real calendar to plan around what you're already doing")
                bullet("lock.fill", "Works offline. Your thoughts never leave the device")
            }
        }
    }

    private var actionButtonPage: some View {
        page(
            icon: "button.horizontal.top.press",
            title: "One press,\nfrom anywhere",
            body: "The whole point is capturing a thought before it's gone. Map your Action Button and Offload opens already listening."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                step("1", "Open Settings → Action Button")
                step("2", "Swipe to Shortcut")
                step("3", "Choose Offload · Quick Capture")
                Text("No Action Button? “Hey Siri, tell Offload” works from the lock screen too.")
                    .font(.Offload.data)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 4)
            }
        }
    }

    private var permissionsPage: some View {
        page(
            icon: "checkmark.shield.fill",
            title: "What Offload\nneeds access to",
            body: "Each one is optional and used for exactly one thing. Nothing is uploaded."
        ) {
            VStack(spacing: 10) {
                permissionRow(
                    icon: "mic.fill", title: "Microphone & speech",
                    detail: "So you can speak instead of type. Transcribed on-device.",
                    granted: micGranted
                ) {
                    micGranted = await TranscriptionService().requestAuthorization()
                }
                permissionRow(
                    icon: "calendar", title: "Calendar",
                    detail: "To plan around your real day and add appointments you capture.",
                    granted: calendarGranted
                ) {
                    calendarGranted = await EventKitCalendarReader().requestAccess()
                }
                permissionRow(
                    icon: "bell.fill", title: "Notifications",
                    detail: "Reminders when things are due, and an optional morning brief.",
                    granted: notificationsGranted
                ) {
                    notificationsGranted = await NotificationService.shared.requestAuthorization()
                    remindersEnabled = notificationsGranted
                }
            }
        }
    }

    private var appearancePage: some View {
        page(
            icon: "paintbrush.fill",
            title: "How should it\nlook?",
            body: "You can change this any time in Settings."
        ) {
            HStack(spacing: 10) {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        themeRaw = theme.rawValue
                        Haptics.light()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: theme.icon)
                                .font(.system(size: 18, weight: .semibold))
                            Text(theme.label)
                                .font(.caption).fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            themeRaw == theme.rawValue ? .white.opacity(0.22) : .white.opacity(0.08),
                            in: .rect(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(themeRaw == theme.rawValue ? 0.5 : 0.12),
                                              lineWidth: 1)
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: Building blocks

    private func page<Content: View>(
        icon: String, title: String, body: String, @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 40)

                Text(title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .tracking(-0.8)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text(body)
                    .font(.Offload.body)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                content()
                    .padding(.top, 6)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 28)
        }
        .scrollIndicators(.hidden)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.14), in: .rect(cornerRadius: 8, style: .continuous))
            Text(text)
                .font(.Offload.body)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(number)
                .font(.system(.caption, design: .rounded)).fontWeight(.bold)
                .foregroundStyle(Color(hex: 0x2E3B8C))
                .frame(width: 24, height: 24)
                .background(.white, in: .circle)
            Text(text)
                .font(.Offload.body)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
        }
    }

    private func permissionRow(
        icon: String, title: String, detail: String, granted: Bool,
        request: @escaping () async -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.14), in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.Offload.data)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.Offload.green)
                    .font(.title3)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    Task { await request(); Haptics.light() }
                } label: {
                    Text("Allow")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.white, in: .capsule)
                        .foregroundStyle(Color(hex: 0x2E3B8C))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(14)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 14, style: .continuous))
        .animation(Motion.standard, value: granted)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(index == page ? 0.95 : 0.3))
                    .frame(width: index == page ? 20 : 7, height: 7)
                    .animation(Motion.standard, value: page)
            }
        }
        .padding(.bottom, 18)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if page < pageCount - 1 {
                Button("Skip") { finish() }
                    .font(.Offload.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .buttonStyle(.pressable)
            }
            Spacer()
            Button {
                if page < pageCount - 1 {
                    withAnimation(Motion.page) { page += 1 }
                    Haptics.light()
                } else {
                    finish()
                }
            } label: {
                Text(page < pageCount - 1 ? "Continue" : "Start capturing")
                    .font(.Offload.taskTitle)
                    .padding(.horizontal, 26).padding(.vertical, 14)
                    .background(.white, in: .capsule)
                    .foregroundStyle(Color(hex: 0x2E3B8C))
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }

    private func finish() {
        Haptics.success()
        withAnimation(Motion.settle) { completed = true }
    }
}
