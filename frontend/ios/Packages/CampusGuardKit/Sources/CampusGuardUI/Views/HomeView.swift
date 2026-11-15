import SwiftUI
import TagKit

/// Frame 3: one bag. Normal = no detection; Alert = the tag watches for theft.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmLost = false

    var body: some View {
        let protected = model.isProtected
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DisplayTitle(lines: protected
                    ? [Text("You’ve ") + Text("left").font(CG.serifItalic(46, bold: true)), Text("your bag")]
                    : [Text("Your bag is"), Text("with you").font(CG.serifItalic(46, bold: true))],
                    size: 46)
                .font(CG.display(46, weight: .regular))
                .foregroundStyle(CG.cardinal)
                .frame(minHeight: 116, alignment: .topLeading)
                .contentTransition(.interpolate)
                .animation(.smooth, value: protected)
                .padding(.top, 44)
                .accessibilityAddTraits(.isHeader)

                if model.mode == .alarm {
                    HStack(spacing: 24) {
                        Button("open alarm") { model.openIncident(.motion, page: .red) }
                            .foregroundStyle(CG.crimson)
                        Button("quiet tracking") { model.openIncident(.motion, page: .white) }
                            .foregroundStyle(CG.ink)
                    }
                    .buttonStyle(SerifLinkStyle(size: 22))
                    .padding(.top, 20)
                }

                if model.snapshot.lostMode && model.usesTag {
                    LostModeCard().padding(.top, 20)
                }

                BagMark(protected: protected)
                    .padding(.vertical, 28)

                ModeToggle()
                LinkStatusLine()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                Button {
                    if model.incident != nil { model.show(.white) }
                    else if model.lostModeAvailable && !model.snapshot.lostMode { confirmLost = true }
                    else { Task { await model.markLost(startTagLostMode: false) } }
                } label: {
                    Text(model.incident != nil || model.snapshot.lostMode ? "View tracking" : "Mark as lost")
                }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 28)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(CG.page.ignoresSafeArea())
        .toolbar(.hidden)
        .refreshable { model.link.stop(); model.link.start() }
        .confirmationDialog("Put your tag in lost mode?", isPresented: $confirmLost, titleVisibility: .visible) {
            Button("Start lost mode") { Task { await model.markLost(startTagLostMode: true) } }
            Button("Just track it") { Task { await model.markLost(startTagLostMode: false) } }
        } message: {
            Text("The tag turns Wi-Fi off and broadcasts its Find My beacon, so nearby iPhones can locate it. It checks in about every 3 minutes; commands wait until then.")
        }
    }
}

/// Normal / Alert segmented control. Changes only when the tag confirms.
private struct ModeToggle: View {
    @Environment(AppModel.self) private var model
    @Namespace private var ns

    var body: some View {
        let on = model.isProtected
        let pending = model.link.pending?.command
        HStack(spacing: 4) {
            segment("Normal", icon: "shield.slash", selected: !on, pending: pending == .disarm) {
                Task { await model.setProtected(false) }
            }
            segment("Alert", icon: "checkmark.shield", selected: on, pending: pending == .arm) {
                Task { await model.setProtected(true) }
            }
        }
        .padding(4)
        .overlay(Capsule().strokeBorder(CG.hairline))
        .disabled(model.busy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Protection mode")
    }

    private func segment(_ title: String, icon: String, selected: Bool, pending: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if pending { ProgressView().controlSize(.small).tint(CG.cardinal) }
                else { Image(systemName: icon) }
                Text(pending ? (title == "Alert" ? "Preparing…" : "Sending…") : title)
            }
            .font(CG.sans(15, .semibold))
            .foregroundStyle(selected ? .white : (pending ? CG.cardinal : CG.muted))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background {
                if selected { Capsule().fill(CG.cardinal).matchedGeometryEffect(id: "sel", in: ns) }
                else if pending { Capsule().fill(CG.blush) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(pending ? "Waiting for the tag to confirm" : "")
    }
}

/// ESP32 lost mode: beacon on, Wi-Fi off, check-ins every ~3 min.
struct LostModeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snap = model.snapshot
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            VStack(alignment: .leading, spacing: 8) {
                Label("Lost mode on", systemImage: "dot.radiowaves.left.and.right")
                    .font(CG.sans(15, .semibold))
                    .foregroundStyle(CG.crimson)
                Text("The tag is broadcasting its Find My beacon with Wi-Fi off.")
                    .font(CG.sans(13))
                    .foregroundStyle(CG.ink)
                Group {
                    if let last = snap.lastCheckInAt { Text("Last check-in \(relative(last, ctx.date))") }
                    if let next = snap.nextCheckInEstimate() {
                        Text(next > ctx.date ? "Next check-in \(relative(next, ctx.date))" : "Check-in due now")
                    }
                    if snap.sirenOn { Text("Siren is on").bold().foregroundStyle(CG.crimson) }
                }
                .font(CG.sans(12))
                .foregroundStyle(CG.muted)
            }
        }
        .cgCard(tint: CG.blush)
    }
}
