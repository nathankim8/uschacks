import SwiftUI
import TagKit

/// App entry view: setup on every fresh launch (product decision), then Home/Settings tabs.
/// Any open alarm or lost report is shown full-screen above the tabs.
public struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            switch model.phase {
            case .welcome:
                WelcomeView()
                    .transition(.opacity)
            case .ready:
                MainTabs()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: model.phase)
        .tint(CG.cardinal)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.enteredBackground()
            default: break
            }
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack { HomeView() }
            }
            Tab("Activity", systemImage: "list.bullet.rectangle") {
                NavigationStack { ActivityView() }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(for: .seconds(banner.tone == .error ? 8 : 5))
                        if model.banner?.id == banner.id { model.banner = nil }
                    }
            }
        }
        .animation(.snappy, value: model.banner)
        .cgFullScreen(isPresented: Binding(get: { model.incident != nil }, set: { _ in })) {
            IncidentView()
                .environment(model)
        }
    }
}
