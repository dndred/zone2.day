import SwiftUI
import Zone2Kit
import Zone2UI

@main
struct Zone2App: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        WakeMonitor.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab(String(localized: "Today"), systemImage: "sun.max") {
                    TodayView(context: context, syncing: model.syncing)
                }
                Tab(String(localized: "Calendar"), systemImage: "calendar") {
                    CalendarView(context: context, syncing: model.syncing)
                }
                Tab(String(localized: "Activities"), systemImage: "figure.run") {
                    ActivitiesView(context: context)
                }
                Tab(String(localized: "Profile"), systemImage: "person.crop.circle") {
                    HomeView(model: model, health: model.health)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                BackgroundRefresh.schedule()
                #if DEBUG
                Task { await WakeMonitor.record("foreground") }
                #endif
                Task { await model.sync() }
            case .background:
                BackgroundRefresh.schedule()
            default: break
            }
        }
        // Background URLSession finished uploads while the app was suspended/terminated.
        .backgroundTask(.urlSession(BackgroundUploader.identifier)) {
            await model.health.uploader.waitForEvents()
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskId)) {
            BackgroundRefresh.schedule()
            #if DEBUG
            await WakeMonitor.record("bg.refresh")
            #endif
            await model.sync(budget: 20)
        }
    }

    private var context: PlanContext {
        let model = model
        return PlanContext(store: model.store) { await model.pull() }
    }
}
