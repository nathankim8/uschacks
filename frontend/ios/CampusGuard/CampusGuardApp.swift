import SwiftUI
import CampusGuardUI

@main
struct CampusGuardApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRefresh.schedule() }
        }
        // iOS wakes the app now and then (not on a schedule we control) to catch up on tag
        // alerts once. It never loops, so it can't trip ntfy's per-IP rate limit.
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await model.backgroundRefresh()
            BackgroundRefresh.schedule()
        }
        #endif
    }
}

#if os(iOS)
import BackgroundTasks

enum BackgroundRefresh {
    static let identifier = "com.campusguard.app.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
