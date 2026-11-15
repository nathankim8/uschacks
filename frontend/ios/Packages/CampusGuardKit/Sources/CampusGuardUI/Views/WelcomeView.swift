import SwiftUI
import TagKit

/// Frames 1-2: search → permissions → connecting (a real PUSHTEST round trip; the shield fills).
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Equatable { case search, connecting, failed(String), done }
    @State private var step: Step = .search
    @State private var showPermissions = false
    @State private var showSetup = false
    @State private var progress = 0.0
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayTitle(lines: [Text("Welcome").font(CG.serifItalic(46, bold: true)) + Text(" to"),
                                 Text("Campus"), Text("Guard.")], size: 46)
                .font(CG.display(46, weight: .regular))
                .foregroundStyle(CG.cardinal)
                .padding(.top, 60)
                .accessibilityAddTraits(.isHeader)

            switch step {
            case .search: search
            default: connecting
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 430, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(CG.page.ignoresSafeArea())
        .sheet(isPresented: $showPermissions) {
            PermissionSheet {
                showPermissions = false
                if model.isConfigured { startConnecting() } else { showSetup = true }
            }
        }
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                ConnectionView(onboarding: true) { saved in
                    showSetup = false
                    if saved { startConnecting() }
                }
            }
        }
        .task(id: attempt) {
            guard step == .connecting else { return }
            await runConnect()
        }
    }

    private var search: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Ripple(delay: Double(i) * 1.2, animate: !reduceMotion)
            }
            Button {
                Task {
                    // Ask only what hasn't been decided yet; returning users go straight to connecting.
                    if await Notifier.shared.needsPrompt() || LocationService.shared.needsPrompt {
                        showPermissions = true
                    } else if model.isConfigured {
                        startConnecting()
                    } else {
                        showSetup = true
                    }
                }
            } label: {
                VStack(spacing: 8) {
                    Text("Searching").font(CG.display(28, weight: .regular))
                    Text("please keep your device\nnearby").font(CG.sans(13)).multilineTextAlignment(.center)
                    Text("Connect")
                        .font(CG.sans(13, .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(CG.ink.opacity(0.6)))
                        .padding(.top, 8)
                }
                .foregroundStyle(CG.ink)
                .frame(width: 250, height: 250)
                .background(CG.rose, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Allows notifications and location, then connects to your tag")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connecting: some View {
        VStack(spacing: 0) {
            ShieldFill(progress: progress)
                .frame(width: 240, height: 240)
                .padding(.top, 110)
                .animation(.linear(duration: 0.15), value: progress)
            Spacer()
            Group {
                if case .failed(let reason) = step {
                    VStack(spacing: 12) {
                        Text("No answer from tag").font(CG.display(26, weight: .regular)).foregroundStyle(CG.cardinal)
                        Text(reason).font(CG.sans(13)).foregroundStyle(CG.muted).multilineTextAlignment(.center)
                        HStack(spacing: 24) {
                            Button("back") { step = .search }
                                .buttonStyle(SerifLinkStyle(size: 22))
                                .foregroundStyle(CG.ink)
                            Button("Try again") { startConnecting() }
                                .buttonStyle(PillButtonStyle())
                                .frame(width: 150)
                        }
                        Button("Check connection settings") { showSetup = true }
                            .font(CG.sans(12)).foregroundStyle(CG.muted)
                        Button("Continue without the tag") { model.finishSetup(linked: false) }
                            .font(CG.sans(12)).underline().foregroundStyle(CG.muted)
                    }
                } else {
                    VStack(spacing: 4) {
                        Text(step == .done ? "Setup complete" : "Connecting…")
                            .font(CG.sans(24, .medium))
                            .foregroundStyle(CG.cardinal)
                            .contentTransition(.opacity)
                        Text("\(Int(progress * 100))%").font(CG.sans(12)).foregroundStyle(CG.muted).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue("\(Int(progress * 100)) percent")
                }
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }

    private func startConnecting() {
        progress = 0
        step = .connecting
        attempt += 1
    }

    private func runConnect() async {
        // The tag polls every 6 s, so ease toward 90% until it answers.
        let ticker = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                progress = 0.9 * (1 - exp(-Date().timeIntervalSince(start) / 3.5))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let outcome = await model.connect()
        ticker.cancel()
        // The user tapped "back" while waiting: don't jump ahead.
        guard step == .connecting || model.phase == .ready else { return }
        switch outcome {
        case .confirmed, .sent:
            progress = 1
            step = .done
            Haptics.success()
            try? await Task.sleep(for: .milliseconds(700))
            if model.phase == .welcome { model.finishSetup(linked: true) }
        case .failed(let failure):
            progress = 0
            Haptics.warning()
            step = .failed(model.failureText(failure, .pushTest))
        }
    }
}

private struct Ripple: View {
    let delay: Double
    let animate: Bool
    @State private var on = false

    var body: some View {
        Circle()
            .strokeBorder(Color(red: 0.788, green: 0.604, blue: 0.600), lineWidth: 1.5) // #C99A99
            .frame(width: 250, height: 250)
            .scaleEffect(on ? 1.8 : 1)
            .opacity(on ? 0 : 0.9)
            .onAppear {
                guard animate else { return }
                withAnimation(.easeOut(duration: 3.6).repeatForever(autoreverses: false).delay(delay)) { on = true }
            }
            .accessibilityHidden(true)
    }
}

/// Design sheet: "Allow *location*", then "Allow *notifications*". No "Not now" (product decision).
private struct PermissionSheet: View {
    var done: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: step == 0 ? "mappin.and.ellipse" : "bell")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(CG.cardinal)
                .frame(width: 44, height: 44)
                .background(Color(red: 0.965, green: 0.933, blue: 0.933), in: .circle) // #F6EEEE
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)

            (Text("Allow ") + Text(step == 0 ? "location" : "notifications").font(CG.serifItalic(31, bold: true)))
                .font(CG.display(31, weight: .regular))
                .foregroundStyle(CG.cardinal)
                .padding(.top, 20)
                .accessibilityAddTraits(.isHeader)

            Text(step == 0
                 ? "We pin where you were when an alert arrives, so you know where to look"
                 : "We only send you notifications when your bag is at risk")
                .font(CG.sans(14))
                .lineSpacing(4)
                .foregroundStyle(Color(red: 0.231, green: 0.208, blue: 0.208)) // #3B3535
                .padding(.top, 12)

            Spacer(minLength: 24)

            Button(step == 0 ? "Continue" : "Allow notifications") {
                Task {
                    if step == 0 {
                        LocationService.shared.requestAuthorization()
                        withAnimation(.snappy) { step = 1 }
                    } else {
                        await Notifier.shared.requestAuthorization()
                        done()
                    }
                }
            }
            .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(320)])
        .presentationCornerRadius(28)
        .presentationBackground(.white)
        .interactiveDismissDisabled()
    }
}
