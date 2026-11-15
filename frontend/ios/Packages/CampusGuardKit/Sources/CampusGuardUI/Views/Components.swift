import SwiftUI
import TagKit

/// One honest line about the tag: what it last reported and how long ago. The Pico/v10 tag has
/// no heartbeat, so the app never claims "online".
struct LinkStatusLine: View {
    @Environment(AppModel.self) private var model
    var onDark = false

    var body: some View {
        if model.isConfigured {
            TimelineView(.periodic(from: .now, by: model.busy ? 1 : 15)) { context in
                let (dot, text, isError) = describe(now: context.date)
                HStack(spacing: 8) {
                    Circle()
                        .fill(onDark ? .white : dot)
                        .frame(width: 8, height: 8)
                        .symbolEffect(.pulse, isActive: model.busy)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(onDark ? .white.opacity(isError ? 1 : 0.85) : (isError ? CG.crimson : CG.muted))
                        .fontWeight(isError && onDark ? .semibold : .regular)
                        .contentTransition(.opacity)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(text)
            }
        }
    }

    private func describe(now: Date) -> (Color, String, Bool) {
        let link = model.link
        let snap = link.snapshot
        if !model.tagLinked { return (CG.hairline, "Not linked to the tag on this phone", false) }
        if let pending = link.pending {
            let secs = max(0, Int(now.timeIntervalSince(pending.sentAt)))
            if pending.waitsForCheckIn {
                let next = snap.nextCheckInEstimate().map { " · next check-in \(relative($0, now))" } ?? ""
                return (CG.amber, "Queued \(label(pending.command)) for the tag's next check-in\(next)", false)
            }
            return (CG.amber, "Sending \(label(pending.command)) to tag… \(secs)s", false)
        }
        if let failure = link.lastFailure, failure != .busy {
            return (CG.crimson, model.failureText(failure, .ping), true)
        }
        let state: String = switch snap.mode {
        case .alarm: "Tag ALARM"
        case .alert: "Tag in Alert"
        case .normal: "Tag in Normal"
        case .unknown: "Tag linked"
        }
        var parts = [snap.lostMode ? "Lost mode" : state]
        if snap.lostMode, let checkIn = snap.lastCheckInAt {
            parts.append("checked in \(relative(checkIn, now))")
        } else if let last = snap.lastReportAt {
            parts.append("last message \(relative(last, now))")
        } else {
            parts.append("no messages yet")
        }
        switch link.stream {
        case .reconnecting: parts.append("reconnecting…")
        case .connecting: parts.append("connecting…")
        default: break
        }
        let dot: Color = snap.mode == .alarm ? CG.alarmRing : (link.stream == .live ? CG.ok : CG.amber)
        return (dot, parts.joined(separator: " · "), false)
    }

    private func label(_ c: TagCommand) -> String {
        switch c {
        case .arm: "Alert"
        case .disarm: "Normal"
        case .pushTest: "test"
        case .lostMode: "lost mode"
        case .found: "found"
        default: c.rawValue.lowercased()
        }
    }
}

func relative(_ date: Date, _ now: Date = .now) -> String {
    let s = now.timeIntervalSince(date)
    if s < 0 { return "in \(Duration.seconds(-s).formatted(.units(allowed: [.minutes, .seconds], width: .narrow, maximumUnitCount: 1)))" }
    if s < 45 { return "just now" }
    return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
}

/// Top control on the red/white screens: arrows, two page dots and the swipe hint.
struct ViewSwitch: View {
    var page: Incident.Page
    var onDark: Bool
    var go: (Incident.Page) -> Void

    var body: some View {
        HStack {
            arrow("chevron.left", target: .red, label: "Active alarm")
            Spacer()
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    dot(on: page == .red)
                    dot(on: page == .white)
                }
                Text("swipe")
                    .font(.caption2)
                    .textCase(.uppercase)
                    .tracking(1.5)
                    .opacity(0.7)
            }
            .accessibilityHidden(true)
            Spacer()
            arrow("chevron.right", target: .white, label: "Quiet tracking")
        }
        .foregroundStyle(onDark ? .white : CG.ink)
    }

    private func dot(on: Bool) -> some View {
        Capsule()
            .fill(onDark ? Color.white : CG.cardinal)
            .opacity(on ? 1 : 0.3)
            .frame(width: on ? 18 : 7, height: 7)
            .animation(.snappy, value: on)
    }

    private func arrow(_ symbol: String, target: Incident.Page, label: String) -> some View {
        Button { go(target) } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(.foreground.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .disabled(page == target)
        .opacity(page == target ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}

/// The bag on Home: calm outline in Normal, filled cardinal with a shield badge in Alert.
struct BagMark: View {
    var protected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: protected ? "backpack.fill" : "backpack")
                .font(.system(size: 120, weight: .light))
                .foregroundStyle(protected ? CG.cardinal : CG.rose)
                .contentTransition(.symbolEffect(.replace))
            Image(systemName: protected ? "checkmark.shield.fill" : "shield.slash")
                .font(.system(size: 34))
                .foregroundStyle(protected ? CG.crimson : CG.muted)
                .background(Circle().fill(CG.page).padding(-6))
                .offset(x: 14, y: 6)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(protected ? "Bag protected" : "Bag not protected")
    }
}

/// Trojan shield that fills grey → red from the bottom while the tag answers.
struct ShieldFill: View {
    var progress: Double

    var body: some View {
        ZStack {
            Image("TrojanShield", bundle: .main)
                .resizable()
                .scaledToFit()
                .saturation(0)
                .brightness(0.2)
                .opacity(0.6)
            Image("TrojanShield", bundle: .main)
                .resizable()
                .scaledToFit()
                .mask(alignment: .bottom) {
                    GeometryReader { geo in
                        Rectangle()
                            .frame(height: geo.size.height * min(1, max(0, progress)))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
        }
        .accessibilityHidden(true)
    }
}

struct BannerView: View {
    let banner: AppModel.Banner
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(banner.text)
                .font(.footnote)
                .foregroundStyle(CG.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(CG.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(tint.opacity(0.3)))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var icon: String {
        switch banner.tone {
        case .info: "paperplane.fill"
        case .warning: "hourglass"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch banner.tone {
        case .info: CG.ok
        case .warning: CG.amber
        case .error: CG.crimson
        }
    }
}

extension View {
    /// Full-screen on iPhone; a sheet where full-screen covers don't exist.
    @ViewBuilder
    func cgFullScreen<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }

    @ViewBuilder
    func cgInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
