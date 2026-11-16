import SwiftUI

/// Five tabs: today's summary, every health category, fitness (gym,
/// nutrition, body, achievements), the watch with pairing inside, and settings
/// with diagnostics inside.
struct RootView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator

    var body: some View {
        TabView {
            DashboardView(dashboard: coordinator.dashboard)
                .tabItem { Label("Summary", systemImage: "heart.text.square.fill") }

            BrowseView()
                .tabItem { Label("Browse", systemImage: "square.grid.2x2.fill") }

            FitnessView()
                .tabItem { Label("Fitness", systemImage: "figure.strengthtraining.traditional") }

            WatchView()
                .tabItem { Label("My Watch", systemImage: "applewatch") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
