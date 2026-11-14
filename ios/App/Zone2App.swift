import SwiftUI
import Zone2Kit
import Zone2UI

@main
struct Zone2App: App {
    private let client = APIClient(baseURL: AppEnvironment.serverURL())

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            TabView {
                Tab("Status", systemImage: "antenna.radiowaves.left.and.right") { status }
                Tab("S1", systemImage: "stethoscope") { S1SpikeView() }
            }
            #else
            status
            #endif
        }
    }

    private var status: some View {
        RootView(serverURL: client.baseURL) { [client] in
            try await client.health()
        }
    }
}
