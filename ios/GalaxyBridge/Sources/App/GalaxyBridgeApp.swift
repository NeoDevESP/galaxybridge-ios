import SwiftUI

@main
struct GalaxyBridgeApp: App {
    @StateObject private var coordinator = BridgeCoordinator()
    @AppStorage("onboarding.done") private var onboarded = false
    @State private var splash = true
    @Environment(\.scenePhase) private var phase

    init() {
        Breadcrumbs.startRun(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        )
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if onboarded {
                    RootView()
                } else {
                    OnboardingView { withAnimation { onboarded = true } }
                }
                if splash {
                    SplashView { withAnimation(.easeOut(duration: 0.35)) { splash = false } }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .environmentObject(coordinator)
            .environmentObject(coordinator.fitness)
            .task {
                await coordinator.onAppear()
                Reminders.reschedule(fitness: coordinator.fitness)
            }
            .onChange(of: phase) { _, value in
                coordinator.setActive(value != .background)
            }
        }
    }
}
