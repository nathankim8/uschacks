import SwiftUI
import MapKit
import TagKit

/// Frames 4-5: red (sound, "It's me") and white (quiet tracking) side by side.
/// Swipe or use the arrows; dragging the map never switches pages.
struct IncidentView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Incident.Page? = .red

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    AlarmPage(go: go)
                        .frame(width: geo.size.width)
                        .id(Incident.Page.red)
                    RecoverPage(go: go)
                        .frame(width: geo.size.width)
                        .id(Incident.Page.white)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea(edges: .horizontal)
        .background(LinearGradient(colors: [CG.alarm, CG.alarm, CG.page, CG.page], startPoint: .leading, endPoint: .trailing).ignoresSafeArea())
        .onAppear {
            page = model.incident?.page ?? .red
            if page == .red { model.show(.red) }   // the red page sounds on its own
        }
        .onChange(of: model.incident?.page) { _, new in
            if let new, new != page { withAnimation(.smooth) { page = new } }
        }
        .onChange(of: page) { _, new in
            if let new, new != model.incident?.page { model.show(new) }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.banner)
    }

    private func go(_ target: Incident.Page) {
        withAnimation(.smooth) { page = target }
    }
}

// MARK: Red

private struct AlarmPage: View {
    @Environment(AppModel.self) private var model
    var go: (Incident.Page) -> Void
    @State private var bellPressed = false

    var body: some View {
        let lost = model.incident?.reason == .lost
        let disarming = model.link.pending?.command == .disarm
        VStack(alignment: .leading, spacing: 0) {
            ViewSwitch(page: .red, onDark: true, go: go)
            DisplayTitle(lines: lost ? [Text("Device lost")] : [Text("Motion"), Text("detected")], size: 48)
                .font(CG.display(48))
                .shadow(color: Color(red: 0.24, green: 0, blue: 0).opacity(0.35), radius: 1.5, y: 2)
                .padding(.top, 32)
                .accessibilityAddTraits(.isHeader)

            Button {
                bellPressed.toggle()
                Task { await model.toggleTagSiren() }
            } label: {
                ZStack {
                    Circle().fill(CG.alarmRing).shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                    Circle().fill(CG.alarmBright).padding(36)
                        .phaseAnimator([false, true], trigger: model.bellActive) { content, on in
                            content.scaleEffect(model.bellActive && on ? 1.04 : 1)
                        } animation: { _ in .easeInOut(duration: 0.5) }
                    Image(systemName: model.bellActive ? "bell.and.waves.left.and.right.fill" : "bell")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(Color(red: 0.63, green: 0.07, blue: 0.10))
                        .symbolEffect(.wiggle, options: .repeating, isActive: model.bellActive)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(maxWidth: 320)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.top, 32)
            .accessibilityLabel(model.bellActive ? "Stop the siren on your bag" : "Sound the siren on your bag")
            .sensoryFeedback(.impact(weight: .heavy), trigger: bellPressed)

            Spacer(minLength: 24)

            LinkStatusLine(onDark: true).padding(.bottom, 12)

            if model.usesTag, model.link.lastFailure == .noConfirmation, !model.busy {
                Button("Close on this phone only (the tag may still be sounding)") { model.dismissLocally() }
                    .font(CG.sans(12)).underline()
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 12)
            }

            HStack(alignment: .bottom) {
                Button(disarming ? "Disarming…" : "It’s me") {
                    Task { await model.itsMe() }
                }
                .buttonStyle(SerifLinkStyle(size: 28))
                .disabled(disarming)
                Spacer()
                Button { go(.white) } label: { Text("passive ⟶") }
                    .buttonStyle(SerifLinkStyle(underline: false, size: 28))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CG.alarm)
    }
}

// MARK: White

private struct RecoverPage: View {
    @Environment(AppModel.self) private var model
    var go: (Incident.Page) -> Void
    @State private var ringing = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var selection: String?

    private struct Point: Identifiable, Equatable {
        enum Kind { case findMy, phone }
        let id: String
        let kind: Kind
        let date: Date
        let coordinate: CLLocationCoordinate2D
        let accuracy: Double?
        static func == (a: Point, b: Point) -> Bool { a.id == b.id }
    }

    private var points: [Point] {
        let findMy = model.findMy.reports.prefix(30).map {
            Point(id: "fm-\($0.id)", kind: .findMy, date: $0.date,
                  coordinate: .init(latitude: $0.lat, longitude: $0.lon), accuracy: $0.accuracy_m.map(Double.init))
        }
        let since = (model.incident?.startedAt ?? .now).addingTimeInterval(-24 * 3600)
        let phone = model.pins.filter { $0.date > since }.map {
            Point(id: "pin-\($0.id)", kind: .phone, date: $0.date, coordinate: $0.coordinate, accuracy: $0.accuracy)
        }
        return (findMy + phone).sorted { $0.date > $1.date }
    }

    var body: some View {
        let lost = model.incident?.reason == .lost
        let pts = points
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ViewSwitch(page: .white, onDark: false, go: go)
                DisplayTitle(lines: lost ? [Text("Device lost")] : [Text("Motion"), Text("Detected")], size: 48)
                    .font(CG.display(48))
                    .foregroundStyle(CG.cardinal)
                    .padding(.top, 32)
                    .accessibilityAddTraits(.isHeader)

                if model.snapshot.lostMode && model.usesTag {
                    LostModeCard().padding(.top, 16)
                }

                map(pts)
                    .frame(height: 260)
                    .clipShape(.rect(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(CG.hairline))
                    .padding(.top, 20)

                findMyStatus.padding(.top, 10)

                if pts.isEmpty {
                    Text(model.findMyConfigured
                         ? "No sightings yet. Find My reports need iPhones passing near the bag and arrive minutes later."
                         : "No sightings yet. Alert pins show where your phone was when an alarm arrived.")
                        .font(CG.sans(13)).foregroundStyle(CG.muted).padding(.top, 12)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(pts.prefix(12).enumerated()), id: \.element.id) { i, p in
                            sightingRow(p, emphasized: i < 2)
                        }
                    }
                    .padding(.top, 12)
                }

                ringButton.padding(.top, 20)

                LinkStatusLine().padding(.top, 24)

                HStack(alignment: .bottom) {
                    Button { go(.red) } label: { Text("⟵ active") }
                        .buttonStyle(SerifLinkStyle(underline: false, size: 28))
                    Spacer()
                    Button("Found") { Task { await model.found() } }
                        .buttonStyle(SerifLinkStyle(size: 28))
                        .disabled(model.busy)
                }
                .foregroundStyle(CG.ink)
                .padding(.top, 12)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(CG.page)
        .task(id: model.findMyConfigured) {
            // Gentle refresh while this screen is open: the helper itself is slow (up to ~60 s).
            while !Task.isCancelled && model.findMyConfigured {
                await model.refreshFindMy()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    @ViewBuilder
    private func map(_ pts: [Point]) -> some View {
        Map(position: $camera, selection: $selection) {
            UserAnnotation()
            ForEach(pts) { p in
                if let acc = p.accuracy, acc > 0 {
                    MapCircle(center: p.coordinate, radius: acc)
                        .foregroundStyle(CG.crimson.opacity(0.08))
                }
                Annotation(p.date.formatted(date: .omitted, time: .shortened), coordinate: p.coordinate) {
                    Image(systemName: p.kind == .findMy ? "backpack.circle.fill" : "iphone.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, p.id == pts.first?.id ? CG.crimson : CG.rose)
                        .shadow(radius: 2)
                }
                .tag(p.id)
            }
            if pts.count > 1 {
                MapPolyline(coordinates: pts.prefix(10).map(\.coordinate))
                    .stroke(CG.crimson.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .including([.university, .library, .cafe, .parking])))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onChange(of: pts.first?.id) { _, _ in
            if let first = pts.first {
                withAnimation { camera = .region(MKCoordinateRegion(center: first.coordinate, latitudinalMeters: 400, longitudinalMeters: 400)) }
            }
        }
        .onChange(of: selection) { _, id in
            if let p = pts.first(where: { $0.id == id }) {
                withAnimation { camera = .region(MKCoordinateRegion(center: p.coordinate, latitudinalMeters: 300, longitudinalMeters: 300)) }
            }
        }
        .accessibilityLabel("Map of where your bag was seen")
    }

    @ViewBuilder
    private var findMyStatus: some View {
        let fm = model.findMy
        if model.findMyConfigured {
            HStack(spacing: 6) {
                if fm.loading { ProgressView().controlSize(.mini) }
                Group {
                    if let error = fm.error { Text(error).foregroundStyle(CG.crimson) }
                    else if let at = fm.fetchedAt { Text("Find My network · updated \(relative(at))") }
                    else { Text("Asking the Find My network…") }
                }
                .font(CG.sans(12))
                .foregroundStyle(CG.muted)
                Spacer()
                Button { Task { await model.refreshFindMy() } } label: { Image(systemName: "arrow.clockwise") }
                    .font(CG.sans(12))
                    .disabled(fm.loading)
                    .accessibilityLabel("Refresh Find My locations")
            }
        }
    }

    private func sightingRow(_ p: Point, emphasized: Bool) -> some View {
        Button { selection = p.id } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(p.date.formatted(date: .omitted, time: .shortened)).bold() + Text(" · \(relative(p.date))"))
                        .font(CG.sans(16))
                    Text("\(p.kind == .findMy ? "Find My network" : "Your phone at the alert")\(p.accuracy.map { " · ±\(Int($0)) m" } ?? "")")
                        .font(CG.sans(11))
                        .opacity(0.75)
                }
                Spacer()
                Link(destination: URL(string: "https://maps.apple.com/?daddr=\(p.coordinate.latitude),\(p.coordinate.longitude)&dirflg=w")!) {
                    Image(systemName: "figure.walk.circle")
                        .font(.title3)
                }
                .accessibilityLabel("Walking directions")
            }
            .foregroundStyle(selection == p.id ? CG.cardinal : (emphasized ? CG.ink : CG.muted))
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var ringButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                ringing.toggle()
                Task { await model.ring(ringing) }
            } label: {
                Label(ringing ? "stop nearby sound" : "play nearby sound",
                      systemImage: ringing ? "speaker.wave.3.fill" : "speaker.slash.fill")
                    .font(CG.serifItalic(21))
                    .symbolEffect(.variableColor.iterative, isActive: ringing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CG.ink)
            .disabled(model.busy)
        }
    }
}
