import SwiftUI

/// The watch itself: what it is, how the link is doing, and the handful of
/// things the phone can genuinely make it do.
///
/// Every control here does something real. There is no watch-face gallery and
/// no app list, because Wear OS exposes neither to a third-party iOS app, and a
/// greyed-out row that never works is worse than no row at all. What the phone
/// cannot do is stated in the "Not available" section instead of being hidden.
struct WatchView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @State private var locateSent = false

    private var client: BridgeClient { coordinator.client }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        PairingView()
                    } label: {
                        Label("Pairing and connection", systemImage: "link")
                    }
                }
                deviceSection
                linkSection
                actionsSection
                mediaSection
                pairingSection
                limitationsSection
            }
            .navigationTitle("My Watch")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    LinkPill(connected: client.isConnected, scanning: client.isScanning)
                }
            }
        }
    }

    private var deviceSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "applewatch.side.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(client.watchHello?.model ?? "Galaxy Watch")
                        .font(.headline)
                    if let hello = client.watchHello {
                        Text("Wear OS " + hello.osVersion + "  ·  app " + hello.appVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not identified yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let battery = client.telemetry?.watchBatteryPct {
                        HStack(spacing: 4) {
                            Image(systemName: batteryIcon(battery))
                            Text("\(battery)%")
                        }
                        .font(.caption)
                        .foregroundStyle(battery <= 15 ? .red : .secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var linkSection: some View {
        Section("Link") {
            capabilityRow(
                "Notifications (ANCS)",
                enabled: client.watchHello?.capabilities.contains("ancs") == true,
                detail: "The watch reads them straight from iOS"
            )
            capabilityRow(
                "Media control (AMS)",
                enabled: client.watchHello?.capabilities.contains("ams") == true,
                detail: "Play, pause and skip from the wrist"
            )
            capabilityRow(
                "Health sync",
                enabled: client.watchHello?.capabilities.contains("health.passive") == true,
                detail: "Steps, heart rate, energy and distance"
            )
            LabeledContent("MTU", value: "\(client.mtu) bytes")
            if let telemetry = client.telemetry {
                LabeledContent("Queued on the watch", value: "\(telemetry.queuedHealthRows) rows")
            }
            if let error = client.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                client.send(.locate, payload: Data())
                locateSent = true
            } label: {
                Label("Buzz the watch", systemImage: "bell.badge.fill")
            }
            .disabled(!client.isConnected)

            if locateSent {
                Text("Sent. The watch buzzes three times.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await coordinator.resync() }
            } label: {
                Label("Sync contacts and calendar now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!client.isConnected)

            Button {
                client.sendTimeSync()
            } label: {
                Label("Re-align the clock", systemImage: "clock.arrow.2.circlepath")
            }
            .disabled(!client.isConnected)

            if !client.isConnected {
                Button {
                    client.start()
                } label: {
                    Label("Look for the watch", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
    }

    @ViewBuilder
    private var mediaSection: some View {
        if let title = client.media.title {
            Section("Playing on this iPhone") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(title)).fontWeight(.medium)
                    if let artist = client.media.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(client.media.playing ? "Playing" : "Paused")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("This mirrors what the watch sees over Apple Media Service. The transport controls live on the watch, which is the side that can drive any app.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var pairingSection: some View {
        Section("Pairing") {
            if let fingerprint = client.keyFingerprint {
                LabeledContent("Key") { Text(fingerprint).monospaced() }
                Text("Must match the key shown on the watch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not paired yet. The Pairing tab has the code entry and finds the watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let status = client.pairingStatus {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var limitationsSection: some View {
        Section("Not available from the iPhone") {
            ForEach(Self.limitations, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.subheadline)
                    Text(item.1).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let limitations: [(String, String)] = [
        ("Watch faces and tiles", "Wear OS exposes no API for a third-party phone app to change them."),
        ("Installing watch apps", "Needs ADB; use the Install tab in the tablet console."),
        ("Firmware updates", "Samsung's own protocol, Android only."),
        ("Answering a call from the wrist", "Depends on Bluetooth hands-free profiles, not on this app."),
    ]

    private func capabilityRow(_ title: String, enabled: Bool, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(title))
                Text(tr(detail)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(enabled ? .green : .secondary)
        }
    }

    private func batteryIcon(_ percent: Int) -> String {
        switch percent {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<70: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
