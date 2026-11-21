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
        S9Mirror.shared.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab(String(localized: "Today"), systemImage: "sun.max") {
                    TodayView(context: context, syncing: model.syncing).signedOutBanner(model)
                }
                Tab(String(localized: "Calendar"), systemImage: "calendar") {
                    CalendarView(context: context, syncing: model.syncing).signedOutBanner(model)
                }
                Tab(String(localized: "Profile"), systemImage: "person.crop.circle") {
                    HomeView(model: model, health: model.health)
                }
            }
            .environment(\.planContext, context)
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
        return PlanContext(store: model.store, refresh: { await model.pull() }, send: { await model.sendQueued() },
                           loadStreams: { id in await model.loadStreams(id) })
    }
}

/// Signed out (tokens revoked or never signed in): the plan on screen is not updating.
private struct SignedOutBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title3)
            Text("Signed out — the plan is not updating")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Button("Sign in") { Task { await model.signIn() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.15))
    }
}

private extension View {
    /// The banner above a tab's content while signed out (not in demo mode).
    func signedOutBanner(_ model: AppModel) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if !model.signedIn && !model.isDemo { SignedOutBanner(model: model) }
        }
    }
}
