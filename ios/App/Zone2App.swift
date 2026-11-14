import SwiftUI
import Zone2Kit

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
            #if DEBUG
            TabView {
                Tab("Home", systemImage: "figure.run") { home }
                Tab("S1", systemImage: "stethoscope") { S1SpikeView() }
                Tab("S4", systemImage: "alarm") { S4WakeView() }
            }
            #else
            home
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                #if DEBUG
                WakeMonitor.scheduleRefresh()
                Task { await WakeMonitor.record("foreground") }
                #endif
                Task { await model.health.sync() }
            case .background:
                #if DEBUG
                WakeMonitor.scheduleRefresh()
                #endif
            default: break
            }
        }
        #if DEBUG
        .backgroundTask(.appRefresh(WakeMonitor.refreshTaskId)) {
            WakeMonitor.scheduleRefresh()
            await WakeMonitor.record("bg.refresh")
            await model.health.sync(budget: 20)
        }
        #endif
    }

    private var home: some View {
        HomeView(model: model, health: model.health)
    }
}
