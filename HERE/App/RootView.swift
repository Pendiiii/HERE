import SwiftUI

struct RootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            MainTabView()
        } else {
            OnboardingView(isComplete: $hasCompletedOnboarding)
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var appModel = appModel
        TabView {
            NavigationStack {
                NearbyView()
            }
            .tabItem { Label("Nearby", systemImage: "location.fill") }

            NavigationStack {
                ActivityView()
            }
            .tabItem { Label("Aktivität", systemImage: "clock") }

            NavigationStack {
                CityClansView()
            }
            .tabItem { Label("Clans", systemImage: "trophy") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
        .sheet(isPresented: $appModel.isComposerPresented) {
            CreatePostView()
                .presentationDetents([.large])
        }
        .task { await appModel.start() }
        .task(id: scenePhase) {
            if scenePhase == .active { await appModel.monitorNearby() }
        }
    }
}
