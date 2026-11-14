import SwiftUI
import Zone2Kit

/// Phase 1 home: account, Apple Health sync, server status. Replaced by Today/Calendar later.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var health: HealthSync
    @State private var server: String = "…"

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if model.signedIn {
                        LabeledContent("Signed in", value: model.me?.name ?? "…")
                        Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                    } else {
                        Button {
                            Task { await model.signIn() }
                        } label: {
                            Label("Sign in with passkey", systemImage: "person.badge.key")
                        }
                    }
                    if let error = model.authError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    if !health.authorized {
                        Button {
                            Task {
                                await health.requestAuthorization()
                                await health.sync()
                            }
                        } label: {
                            Label("Connect Apple Health", systemImage: "heart.text.square")
                        }
                    } else {
                        LabeledContent("Uploaded", value: "\(health.state.uploaded)")
                        LabeledContent("In queue", value: "\(health.state.pending.count)")
                        if let last = health.state.lastSync {
                            LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button {
                            Task { await health.sync() }
                        } label: {
                            Label(health.running ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(health.running || !model.signedIn)
                    }
                    if let error = health.state.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Workouts are uploaded with full detail (heart rate, power, route). First sync uploads your whole history, newest first.")
                }

                Section("Server") {
                    LabeledContent(model.api.baseURL.host() ?? "", value: server)
                        .font(.callout)
                }
            }
            .navigationTitle("zone2.day")
            .refreshable {
                await model.refreshAccount()
                await health.sync()
                await loadServer()
            }
            .task { await loadServer() }
        }
    }

    private func loadServer() async {
        do {
            let h = try await model.api.health()
            server = "\(h.env) · \(h.version)"
        } catch {
            server = "unavailable"
        }
    }
}
