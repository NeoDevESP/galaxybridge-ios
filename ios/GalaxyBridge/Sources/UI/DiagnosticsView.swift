import SwiftUI

/// The raw protocol view: link state and the message log.
///
/// Everything a user acts on moved to the other tabs; what is left is what you
/// need when the bridge misbehaves and someone has to read the frames.
struct DiagnosticsView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator

    var body: some View {
        // Pushed from Settings, so it lives inside that navigation stack.
        List {
            linkSection
            trailSection
            previousRunSection
            logSection
        }
        .navigationTitle("Diagnostics")
        .refreshable { await coordinator.resync() }
    }

    private var linkSection: some View {
        Section("Link") {
            LabeledContent("Watch") {
                Text(coordinator.client.isConnected ? "Connected" : "Not connected")
                    .foregroundStyle(coordinator.client.isConnected ? .green : .secondary)
            }
            if coordinator.client.isScanning {
                LabeledContent("State", value: "Scanning")
            }
            LabeledContent("MTU", value: "\(coordinator.client.mtu)")
            if let hello = coordinator.client.watchHello {
                LabeledContent("Model", value: hello.model)
                LabeledContent("ANCS", value: hello.capabilities.contains("ancs") ? "yes" : "no")
                LabeledContent("AMS", value: hello.capabilities.contains("ams") ? "yes" : "no")
            }
            if let telemetry = coordinator.client.telemetry, let battery = telemetry.watchBatteryPct {
                LabeledContent("Watch battery", value: "\(battery)%")
            }
            if let error = coordinator.client.lastError {
                Text(error).foregroundStyle(.orange).font(.footnote)
            }
        }
    }

    /// Both Bluetooth trails, the iPhone's and the one the watch ships on each
    /// connection, as one file to send when the link misbehaves.
    private var trailSection: some View {
        Section {
            if let report = WatchTrail.report() {
                ShareLink(item: report) {
                    Label("Export Bluetooth log", systemImage: "square.and.arrow.up")
                }
            }
            let watchLines = WatchTrail.lines()
            DisclosureGroup("Watch trail (\(watchLines.count))") {
                Text(watchLines.suffix(60).joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
            DisclosureGroup("iPhone trail") {
                Text(Breadcrumbs.current().split(separator: "\n").suffix(60).joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button("Clear both trails", role: .destructive) {
                Breadcrumbs.clear()
                WatchTrail.clear()
            }
        } header: {
            Text("Bluetooth log")
        } footer: {
            Text("The watch sends its part each time it connects. Nothing personal is recorded: only connection events.")
        }
    }

    /// What the app was doing when it last stopped. A sideloaded build cannot
    /// be attached to a debugger, so this is the only way to see how far a run
    /// that died actually got.
    @ViewBuilder
    private var previousRunSection: some View {
        if !Breadcrumbs.previousRun.isEmpty {
            Section("Previous run") {
                Text(Breadcrumbs.previousRun)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                Button("Clear") { Breadcrumbs.clear() }
            }
        }
    }

    private var logSection: some View {
        Section("Activity") {
            if coordinator.events.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            }
            ForEach(coordinator.events, id: \.self) { line in
                Text(line).font(.system(.footnote, design: .monospaced))
            }
        }
    }
}

#Preview {
    DiagnosticsView().environmentObject(BridgeCoordinator())
}
