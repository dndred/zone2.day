import SwiftUI
import Zone2Kit

/// Profile tab: account, Apple Health, plan sync, server; spikes under Debug in debug builds.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var health: HealthSync
    @State private var server: String = "…"
    @State private var status: SyncStatus?

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
                                await model.sync()
                            }
                        } label: {
                            Label("Connect Apple Health", systemImage: "heart.text.square")
                        }
                    } else {
                        LabeledContent("Uploaded", value: "\(health.state.uploaded)")
                        LabeledContent("Uploading (background)", value: "\(health.uploadingCount + health.exportedCount)")
                        LabeledContent("Waiting for export", value: "\(health.queuedCount)")
                        if let last = health.state.lastSync {
                            LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button {
                            Task { await model.sync() }
                        } label: {
                            Label(health.running ? String(localized: "Syncing…") : String(localized: "Sync now"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(health.running || !model.signedIn)
                    }
                    if let error = health.state.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Workouts are uploaded with full detail (heart rate, power, route). Export from Apple Health needs the app open and the phone unlocked; uploads then continue in the background. First sync covers your whole history, newest first.")
                }

                Section("Plan sync") {
                    if let status {
                        LabeledContent("Records on this iPhone", value: "\(status.records)")
                        if let at = status.lastSyncAt {
                            LabeledContent("Last pull", value: at.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let err = status.lastError {
                            Text(err).font(.caption).foregroundStyle(.orange)
                        }
                        LabeledContent("Cursor", value: status.cursor ?? "—").font(.caption)
                    }
                    Button("Full resync", role: .destructive) {
                        Task {
                            try? model.store.reset()
                            await model.pull()
                        }
                    }
                    .disabled(!model.signedIn)
                }

                Section("Server") {
                    LabeledContent(model.api.baseURL.host() ?? "", value: server)
                        .font(.callout)
                }

                #if DEBUG
                Section("Debug") {
                    NavigationLink("S1 · HealthKit & WorkoutKit") { S1SpikeView() }
                    NavigationLink("S4 · Background wakes") { S4WakeView() }
                }
                #endif
            }
            .navigationTitle("zone2.day")
            .refreshable {
                await model.refreshAccount()
                await model.sync()
                await loadServer()
            }
            .task { await loadServer() }
            .task {
                do {
                    for try await s in model.store.observeStatus() { status = s }
                } catch {}
            }
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
