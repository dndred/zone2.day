import SwiftUI
import Zone2Kit
import Zone2UI

@main
struct Zone2App: App {
    private let client = APIClient(baseURL: AppEnvironment.serverURL())
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
                Tab("Status", systemImage: "antenna.radiowaves.left.and.right") { status }
                Tab("S1", systemImage: "stethoscope") { S1SpikeView() }
                Tab("S4", systemImage: "alarm") { S4WakeView() }
            }
            #else
            status
            #endif
        }
        #if DEBUG
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                WakeMonitor.scheduleRefresh()
                Task { await WakeMonitor.record("foreground") }
            case .background: WakeMonitor.scheduleRefresh()
            default: break
            }
        }
        .backgroundTask(.appRefresh(WakeMonitor.refreshTaskId)) {
            WakeMonitor.scheduleRefresh()
            await WakeMonitor.record("bg.refresh")
        }
        #endif
    }

    private var status: some View {
        RootView(serverURL: client.baseURL) { [client] in
            try await client.health()
        }
    }
}
