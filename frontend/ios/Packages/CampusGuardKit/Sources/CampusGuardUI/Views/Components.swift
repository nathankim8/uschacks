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
                        .font(CG.sans(12))
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

/// Top control on the red/white screens: arrows, two page dots and the swipe hint (design).
struct ViewSwitch: View {
    var page: Incident.Page
    var onDark: Bool
    var go: (Incident.Page) -> Void

    var body: some View {
        HStack(spacing: 12) {
            arrow("chevron.left", target: .red, label: "Red alarm with sound")
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    dot(on: page == .red, first: true)
                    dot(on: page == .white, first: false)
                }
                Text(page == .red ? "Swipe left for quiet tracking" : "Swipe right for sound alarm")
                    .font(CG.sans(11))
                    .tracking(0.3)
                    .foregroundStyle(onDark ? Color.white.opacity(0.8) : CG.muted)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            arrow("chevron.right", target: .white, label: "Quiet white tracking")
        }
    }

    private func dot(on: Bool, first: Bool) -> some View {
        let color: Color = onDark
            ? (on ? .white : .white.opacity(0.4))
            : (on ? CG.cardinal : Color(red: 0.851, green: 0.647, blue: 0.647)) // #D9A5A5
        return Capsule()
            .fill(color)
            .frame(width: on ? 20 : 6, height: 6)
            .animation(.snappy, value: on)
    }

    private func arrow(_ symbol: String, target: Incident.Page, label: String) -> some View {
        Button { go(target) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(onDark ? Color.white : CG.cardinal)
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(onDark ? Color.white.opacity(0.4) : Color(red: 0.894, green: 0.863, blue: 0.855))) // #E4DCDA
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(page == target)
        .opacity(page == target ? 0.25 : 1)
        .accessibilityLabel(label)
    }
}

/// The bag on Home, drawn from the design's SVG (viewBox 240×200): rings, a backpack with its
/// tag, and sound waves from the tag in Alert. Decorative only: no distance, no location.
struct BagMark: View {
    var protected: Bool

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width / 240, size.height / 200)
            ctx.translateBy(x: (size.width - 240 * k) / 2, y: (size.height - 200 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            let ink = CG.cardinal
            let ringColor = Color(red: 0.925, green: 0.863, blue: 0.855) // #ECDCDA
            func circle(_ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: 120 - r, y: 104 - r, width: 2 * r, height: 2 * r))
            }
            ctx.stroke(circle(88), with: .color(ringColor), lineWidth: 1)
            ctx.stroke(circle(66), with: .color(ringColor),
                       style: StrokeStyle(lineWidth: 1, dash: protected ? [2, 6] : []))
            ctx.fill(circle(46), with: .color(protected
                ? Color(red: 0.984, green: 0.945, blue: 0.941)    // #FBF1F0
                : Color(red: 0.973, green: 0.933, blue: 0.925)))  // #F8EEEC

            // Handle: M104 74 c0-9 7-15 16-15 s16 6 16 15
            var handle = Path()
            handle.move(to: CGPoint(x: 104, y: 74))
            handle.addCurve(to: CGPoint(x: 120, y: 59), control1: CGPoint(x: 104, y: 65), control2: CGPoint(x: 111, y: 59))
            handle.addCurve(to: CGPoint(x: 136, y: 74), control1: CGPoint(x: 129, y: 59), control2: CGPoint(x: 136, y: 65))
            ctx.stroke(handle, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // Body
            let pack = Path(roundedRect: CGRect(x: 96, y: 74, width: 48, height: 62), cornerRadius: 16)
            ctx.fill(pack, with: .color(CG.page))
            ctx.stroke(pack, with: .color(ink), lineWidth: 2)

            // Front pocket: M104 106 h32 v18 a6 6 0 0 1 -6 6 h-20 a6 6 0 0 1 -6 -6 z
            var pocket = Path()
            pocket.move(to: CGPoint(x: 104, y: 106))
            pocket.addLine(to: CGPoint(x: 136, y: 106))
            pocket.addLine(to: CGPoint(x: 136, y: 124))
            pocket.addArc(tangent1End: CGPoint(x: 136, y: 130), tangent2End: CGPoint(x: 130, y: 130), radius: 6)
            pocket.addLine(to: CGPoint(x: 110, y: 130))
            pocket.addArc(tangent1End: CGPoint(x: 104, y: 130), tangent2End: CGPoint(x: 104, y: 124), radius: 6)
            pocket.closeSubpath()
            ctx.stroke(pocket, with: .color(ink), lineWidth: 1.6)
            var seam = Path()
            seam.move(to: CGPoint(x: 104, y: 116))
            seam.addLine(to: CGPoint(x: 136, y: 116))
            ctx.stroke(seam, with: .color(ink), lineWidth: 1.2)

            // Strap to the tag
            var strap = Path()
            strap.move(to: CGPoint(x: 144, y: 86))
            strap.addLine(to: CGPoint(x: 156, y: 92))
            ctx.stroke(strap, with: .color(ink), lineWidth: 1.4)

            // Tag, rotated 18° about (159, 98); filled in Alert
            let tagShape = Path(roundedRect: CGRect(x: 152, y: 88, width: 14, height: 20), cornerRadius: 4)
                .applying(CGAffineTransform(translationX: -159, y: -98)
                    .concatenating(CGAffineTransform(rotationAngle: 18 * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: 159, y: 98)))
            ctx.fill(tagShape, with: .color(protected ? ink : CG.page))
            ctx.stroke(tagShape, with: .color(ink), lineWidth: 1.6)

            if protected {
                // Sound waves: M178 82 c5 5 5 13 0 18 · M186 76 c8 9 8 21 0 30
                var waves = Path()
                waves.move(to: CGPoint(x: 178, y: 82))
                waves.addCurve(to: CGPoint(x: 178, y: 100), control1: CGPoint(x: 183, y: 87), control2: CGPoint(x: 183, y: 95))
                waves.move(to: CGPoint(x: 186, y: 76))
                waves.addCurve(to: CGPoint(x: 186, y: 106), control1: CGPoint(x: 194, y: 85), control2: CGPoint(x: 194, y: 97))
                ctx.stroke(waves, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }
        .aspectRatio(240 / 200, contentMode: .fit)
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
        .animation(.smooth, value: protected)
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
                .font(CG.sans(13))
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
