import SwiftUI
import Zone2Kit
import Zone2UI

/// Profile tab: account, Apple Health, races & notebook, watch delivery.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var health: HealthSync
    @State private var status: SyncStatus?
    @State private var watchDelivery = AppEnvironment.watchDelivery()

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
                                model.metrics.startObserving()
                                await model.sync()
                            }
                        } label: {
                            Label("Connect Apple Health", systemImage: "heart.text.square")
                        }
                    } else {
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

                Section {
                    NavigationLink {
                        ZonesView(store: model.store)
                    } label: {
                        Label(ZonesView.title, systemImage: "heart.text.clipboard")
                    }
                    NavigationLink {
                        RacesView(store: model.store)
                    } label: {
                        Label("Races", systemImage: "flag.checkered")
                    }
                    NavigationLink {
                        NotebookView(store: model.store)
                    } label: {
                        Label("Notebook", systemImage: "book")
                    }
                }

                Section {
                    Toggle("Workouts on the watch", isOn: Binding(
                        get: { watchDelivery },
                        set: { on in
                            watchDelivery = on
                            UserDefaults.standard.set(on, forKey: AppEnvironment.watchDeliveryKey)
                            Task { await model.pull() }
                        }
                    ))
                    if let err = syncError {
                        Text(err).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text("Only one copy of the app should put the plan on the watch.")
                }
            }
            .navigationTitle("zone2.day")
            .refreshable {
                await model.refreshAccount()
                await model.sync()
            }
            .task {
                do {
                    for try await s in model.store.observeStatus() { status = s }
                } catch {}
            }
        }
    }

    /// Plan pull, outbox or watch delivery error — the only sync detail worth showing outside Debug.
    private var syncError: String? {
        guard let status else { return nil }
        return status.lastError ?? status.outboxError ?? status.watchError
    }
}
