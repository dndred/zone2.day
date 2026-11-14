import SwiftUI
import Zone2Kit
import Zone2UI

@main
struct Zone2App: App {
    private let client = APIClient(baseURL: AppEnvironment.serverURL())

    var body: some Scene {
        WindowGroup {
            RootView(serverURL: client.baseURL) { [client] in
                try await client.health()
            }
        }
    }
}
