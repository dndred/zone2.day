import SwiftUI
import Zone2Kit

/// Phase 0 placeholder: shows that the app reaches the backend. Replaced by Today/Calendar in phase 1.
public struct RootView: View {
    enum State: Equatable {
        case loading
        case connected(ServerHealth)
        case failed(String)
    }

    private let loadHealth: @Sendable () async throws -> ServerHealth
    private let serverURL: URL
    @SwiftUI.State private var state: State = .loading

    public init(serverURL: URL, loadHealth: @escaping @Sendable () async throws -> ServerHealth) {
        self.serverURL = serverURL
        self.loadHealth = loadHealth
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                    LabeledContent {
                        Text(serverURL.host() ?? serverURL.absoluteString)
                            .font(.callout.monospaced())
                    } label: {
                        Text("Server", bundle: .module)
                    }
                }
            }
            .navigationTitle("zone2.day")
            .refreshable { await refresh() }
            .task { await refresh() }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch state {
        case .loading:
            LabeledContent {
                ProgressView()
            } label: {
                Text("Checking…", bundle: .module)
            }
        case .connected(let health):
            LabeledContent {
                Text("\(health.env) · \(health.version)")
                    .font(.callout.monospaced())
            } label: {
                Label {
                    Text("Connected", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Unavailable", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        do {
            state = .connected(try await loadHealth())
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

#Preview("Connected") {
    RootView(serverURL: AppEnvironment.stagingURL) {
        ServerHealth(ok: true, service: "zone2-api", env: "staging", version: "abc123", time: "")
    }
}

#Preview("Failed") {
    RootView(serverURL: AppEnvironment.stagingURL) {
        throw APIError.status(502, body: "upstream_unreachable")
    }
}
