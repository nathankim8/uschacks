import SwiftUI
import TagKit

/// Everything the tag has said, newest first, grouped by day.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        let groups = Dictionary(grouping: model.link.history) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
        List {
            if groups.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "waveform.path.ecg",
                                       description: Text(model.isConfigured
                                                         ? "Messages from your tag appear here."
                                                         : "Set up your tag in Settings › Connection."))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.key) { day, reports in
                Section(day.formatted(.relative(presentation: .named, unitsStyle: .wide)).capitalized) {
                    ForEach(reports) { ActivityRow(report: $0) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CG.page.ignoresSafeArea())
        .navigationTitle("Activity")
        .toolbar {
            if !model.link.history.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear the activity log on this phone?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.link.clearHistory() }
        }
    }
}

private struct ActivityRow: View {
    let report: TagReport

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(CG.sans(15, .semibold))
                Text(report.text).font(CG.sans(12)).foregroundStyle(CG.muted).lineLimit(3)
            }
            Spacer()
            Text(report.date.formatted(date: .omitted, time: .shortened))
                .font(CG.sans(11)).foregroundStyle(CG.muted).monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch report.event {
        case .alarm: "Alarm"
        case .armed: "Alert mode on"
        case .disarmed: "Normal mode"
        case .found: "Found, lost mode off"
        case .lostModeOn: "Lost mode on"
        case .checkIn: "Lost mode check-in"
        case .status: "Status"
        case .test: "Test"
        case .chirp: "Find-it beeps"
        case .siren: "Siren on"
        case .stop: "Siren off"
        case .wifiBack: "Back online"
        case .boot: "Tag restarted"
        case .unknown, .info: "Message"
        }
    }

    private var icon: String {
        switch report.event {
        case .alarm: "light.beacon.max.fill"
        case .armed: "checkmark.shield.fill"
        case .disarmed: "shield.slash"
        case .found: "hand.thumbsup.fill"
        case .lostModeOn, .checkIn: "dot.radiowaves.left.and.right"
        case .siren, .chirp, .test: "speaker.wave.2.fill"
        case .stop: "speaker.slash.fill"
        case .wifiBack, .boot, .status: "antenna.radiowaves.left.and.right"
        case .unknown, .info: "text.bubble"
        }
    }

    private var tint: Color {
        switch report.event {
        case .alarm, .lostModeOn, .siren: CG.crimson
        case .armed, .found: CG.cardinal
        case .checkIn: CG.amber
        default: CG.muted
        }
    }
}
