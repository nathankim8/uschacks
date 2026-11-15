import SwiftUI
import TagKit

/// Frame 6 plus tag tools and connection settings.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings")
                    .font(CG.display(44))
                    .foregroundStyle(CG.cardinal)
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isHeader)

                tagCard

                section("Trigger alarm") {
                    VStack(spacing: 8) {
                        triggerRow(.automatic, "Automatic", "Your bag sounds its siren as soon as it detects movement", "bolt.fill")
                        triggerRow(.manual, "Manual", "The red screen opens quietly; tap the bell to sound your bag", "hand.raised.fill")
                    }
                }

                section("This phone") {
                    Button {
                        #if os(iOS)
                        if let url = URL(string: "app-settings:") { openURL(url) }
                        #endif
                    } label: {
                        HStack {
                            Label("Notifications", systemImage: "bell.badge")
                            Spacer()
                            Text(Notifier.shared.authorized ? "On" : "Off").foregroundStyle(CG.muted)
                            Image(systemName: "chevron.right").font(CG.sans(12)).foregroundStyle(CG.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    Text("iOS pauses apps in the background. For lock-screen alerts when Campus Guard is closed, also subscribe to your tag's topic in the ntfy app.")
                        .font(CG.sans(11)).foregroundStyle(CG.muted)
                }

                section(nil) {
                    Toggle(isOn: $model.settings.trojanNetwork) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Find My locations")
                            Text("Your tag's beacon is located by iPhones passing by. Locations appear on the tracking screen.")
                                .font(CG.sans(11)).foregroundStyle(CG.muted)
                        }
                    }
                }

                section("More") {
                    NavigationLink { ActivityView() } label: {
                        row("Activity", "list.bullet.rectangle", detail: model.link.history.isEmpty ? "" : "\(model.link.history.count)")
                    }
                    Divider()
                    NavigationLink { ConnectionView(onboarding: false) } label: {
                        row("Connection", "antenna.radiowaves.left.and.right", detail: model.isConfigured ? "Set up" : "Not set up")
                    }
                    Divider()
                    NavigationLink { AboutProtocolView() } label: {
                        row("Tag protocol", "doc.text.magnifyingglass", detail: model.snapshot.structured ? "v11" : "v9/v10")
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
        }
        .tint(CG.crimson)
        .background(CG.page.ignoresSafeArea())
        .toolbar(.hidden)
    }

    private var tagCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.title2)
                    .foregroundStyle(CG.crimson)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your bag tag").font(CG.sans(15, .semibold))
                    if model.isConfigured { LinkStatusLine() }
                    else { Text("Not set up").font(CG.sans(12)).foregroundStyle(CG.muted) }
                }
                Spacer()
                Button("Reconnect") { model.restartSetup() }
                    .font(CG.sans(12, .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .overlay(Capsule().strokeBorder(CG.hairline))
                    .foregroundStyle(CG.cardinal)
            }
            if model.usesTag {
                Divider()
                HStack(spacing: 10) {
                    toolButton("Find it", "dot.radiowaves.left.and.right", .chirp)
                    toolButton("Beep", "speaker.wave.1", .test)
                    toolButton("Test alert", "bell.badge", .pushTest)
                }
                if let fw = model.snapshot.firmware {
                    Text("Firmware \(fw)").font(CG.sans(11)).foregroundStyle(CG.muted)
                }
            }
        }
        .cgCard()
    }

    private func toolButton(_ title: String, _ icon: String, _ command: TagCommand) -> some View {
        Button { Task { await model.run(command) } } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(CG.sans(11, .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(CG.blush, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(CG.cardinal)
        .disabled(model.busy)
    }

    private func triggerRow(_ value: AlertTrigger, _ title: String, _ detail: String, _ icon: String) -> some View {
        let on = model.settings.trigger == value
        return Button { Task { await model.setTrigger(value) } } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(on ? CG.crimson : CG.muted).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(CG.sans(15, .semibold))
                    Text(detail).font(CG.sans(12)).foregroundStyle(CG.muted)
                }
                Spacer()
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? CG.crimson : CG.hairline)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(on ? CG.blush : .clear, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? CG.crimson : CG.hairline))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func section<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title { Text(title).font(CG.sans(15, .semibold)) }
            content()
        }
        .cgCard()
    }

    private func row(_ title: String, _ icon: String, detail: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(detail).foregroundStyle(CG.muted).font(CG.sans(13))
            Image(systemName: "chevron.right").font(CG.sans(12)).foregroundStyle(CG.muted)
        }
        .foregroundStyle(CG.ink)
        .contentShape(.rect)
    }
}

/// Topic, server, tokens, Find My helper. Topic names are secrets (Keychain).
struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onboarding: Bool
    var onFinish: ((Bool) -> Void)? = nil

    @State private var topicInput = ""
    @State private var server = ""
    @State private var commandTopic = ""
    @State private var token = ""
    @State private var findMyURL = ""
    @State private var findMyToken = ""
    @State private var showAdvanced = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Tag topic or ntfy link", text: $topicInput)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .font(.body.monospaced())
            } header: {
                Text("Your tag")
            } footer: {
                Text("The ntfy topic set in your tag's firmware (NTFY_TOPIC), or the link it prints on the Serial Monitor. Anyone with this topic can control the tag, so keep it private.")
            }

            Section {
                TextField("http://192.168.x.x:8000", text: $findMyURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("Access token (optional)", text: $findMyToken)
                    .noPasswordSaving()
            } header: {
                Text("Find My locations")
            } footer: {
                Text("The Campus Guard Find My helper (findmy/server.py). It must be reachable from this phone. Leave empty to show only alert pins.")
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    TextField("Server (https://ntfy.sh)", text: $server)
                        .autocorrectionDisabled()
                    TextField("Command topic (default: <topic>-cmd)", text: $commandTopic)
                        .autocorrectionDisabled()
                    SecureField("ntfy access token (optional)", text: $token)
                        .noPasswordSaving()
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(CG.crimson) }
            }

            if !onboarding && model.isConfigured {
                Section {
                    Button("Remove tag from this phone", role: .destructive) {
                        model.updateConfiguration(nil)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(onboarding ? "Set up your tag" : "Connection")
        .cgInlineTitle()
        .toolbar {
            if onboarding {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish?(false) }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(onboarding ? "Connect" : "Save", action: save)
                    .disabled(topicInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let c = model.configuration else { return }
        topicInput = c.alertTopic
        server = c.server == TagConfiguration.defaultServer ? "" : c.server.absoluteString
        commandTopic = c.commandTopic == "\(c.alertTopic)-cmd" ? "" : c.commandTopic
        token = c.accessToken ?? ""
        findMyURL = c.findMyURL?.absoluteString ?? ""
        findMyToken = c.findMyToken ?? ""
    }

    private func save() {
        guard let parsed = TagConfiguration.parse(topicInput) else {
            error = "That doesn't look like an ntfy topic (letters, digits, - and _ only)."
            return
        }
        var serverURL = parsed.server
        if !server.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
                error = "The server must be an http(s) URL."
                return
            }
            serverURL = url
        }
        var findMy: URL?
        let fm = findMyURL.trimmingCharacters(in: .whitespaces)
        if !fm.isEmpty {
            guard let url = URL(string: fm.contains("://") ? fm : "http://\(fm)"), url.host != nil else {
                error = "The Find My helper address isn't a valid URL."
                return
            }
            findMy = url
        }
        let config = TagConfiguration(server: serverURL, alertTopic: parsed.topic,
                                      commandTopic: commandTopic.isEmpty ? nil : commandTopic,
                                      accessToken: token.isEmpty ? nil : token,
                                      findMyURL: findMy, findMyToken: findMyToken.isEmpty ? nil : findMyToken)
        guard config.isValid else {
            error = "The command topic must be a different, valid topic."
            return
        }
        error = nil
        model.updateConfiguration(config)
        Haptics.success()
        if onboarding { onFinish?(true) } else { dismiss() }
    }
}

struct AboutProtocolView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snap = model.snapshot
        List {
            Section("This tag") {
                LabeledContent("Firmware", value: snap.firmware ?? "v9/v10 (doesn't report)")
                LabeledContent("Machine tags (cg1)", value: snap.structured ? "Yes" : "No, text matching")
                LabeledContent("Request ids", value: snap.acceptsRequestIDs ? "Yes" : "No")
                LabeledContent("Lost mode", value: snap.supportsLostMode ? "Supported (ESP32)" : "Not seen")
            }
            Section {
                Text("The app sends one word to `<topic>-cmd` (ARM, DISARM, LOSTMODE, FOUND, PUSHTEST, TEST, STOP, SIREN, CHIRP, PING) and reads the tag's pushes from `<topic>` over one streaming connection. It never polls in a loop, because ntfy rate-limits per IP and the tag shares your hotspot's IP.")
                Text("Screens change only when the tag confirms. SIREN, STOP, CHIRP and TEST can't be confirmed by v9/v10 firmware, so the app says “Sent”.")
            } header: { Text("How it works") }
        }
        .navigationTitle("Tag protocol")
        .cgInlineTitle()
    }
}

private extension View {
    /// Tokens aren't passwords: keep iOS from offering to save them to Passwords.
    @ViewBuilder
    func noPasswordSaving() -> some View {
        #if os(iOS)
        textContentType(.oneTimeCode).autocorrectionDisabled()
        #else
        self
        #endif
    }
}
