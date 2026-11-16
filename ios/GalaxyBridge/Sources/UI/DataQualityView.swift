import SwiftUI

/// Your data: what is stored, how complete today is, export, and deletion.
///
/// Coverage says how much of the day the watch was actually measuring, the
/// delivery numbers say whether anything is stuck on the watch, and the export
/// hands over the raw samples so they can be read in any other tool.
struct DataQualityView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator

    @State private var coverage: (hoursWithData: Int, samples: Int)?
    @State private var summary = LocalHealthStore.Summary()
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportWindow: HealthTrends.Window = .month
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section("Stored on this iPhone") {
                LabeledContent("Samples", value: "\(summary.samples)")
                LabeledContent("Workouts", value: "\(summary.workouts)")
                if let oldest = summary.oldest {
                    LabeledContent("Since", value: oldest.formatted(date: .abbreviated, time: .omitted))
                }
                LabeledContent(
                    "Size",
                    value: ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
                )
            }

            Section("Coverage today") {
                if let coverage {
                    LabeledContent("Hours with a heart-rate sample", value: "\(coverage.hoursWithData) of 24")
                    LabeledContent("Heart-rate readings", value: "\(coverage.samples)")
                    if coverage.hoursWithData < 12 {
                        Text("Under half the day. A flat chart over a window like this usually means the watch was off the wrist or out of range, not that nothing happened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Reading…").foregroundStyle(.secondary)
                }
            }

            Section("Delivery") {
                if let telemetry = coordinator.client.telemetry {
                    LabeledContent("Waiting on the watch", value: "\(telemetry.queuedHealthRows) rows")
                }
                if let newest = summary.newest {
                    LabeledContent("Newest sample", value: newest.formatted(date: .abbreviated, time: .shortened))
                }
                Text("The watch deletes rows only after this iPhone confirms they are stored, so a backlog means a delay, never a loss.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Export") {
                Picker("Window", selection: $exportWindow) {
                    ForEach(HealthTrends.Window.allCases) { option in
                        Text("\(option.rawValue) days").tag(option)
                    }
                }
                Button {
                    Task { await export() }
                } label: {
                    if exporting {
                        HStack {
                            ProgressView()
                            Text("Collecting samples…")
                        }
                    } else {
                        Label("Build CSV", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(exporting)

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share \(exportURL.lastPathComponent)", systemImage: "paperplane")
                    }
                }
                if let error = coordinator.trends.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(Self.caveats, id: \.self) { line in
                    Text(line).font(.caption)
                }
            } header: {
                Text("How to read the numbers")
            }

            Section {
                Button("Delete all health data", role: .destructive) {
                    confirmDelete = true
                }
            } footer: {
                Text("Removes every sample and workout from this iPhone. The watch does not keep a copy.")
            }
        }
        .navigationTitle("Your data")
        .task { await load() }
        .confirmationDialog(
            "Delete all health data stored in GalaxyBridge? This cannot be undone.",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                Task {
                    try? await coordinator.store.deleteAll()
                    await coordinator.dashboard.refresh()
                    await load()
                }
            }
        }
    }

    private static let caveats = [
        "Days without samples are left out of charts and averages rather than drawn as zero.",
        "Resting heart rate is estimated from the lowest stretch of each day.",
        "Only what this watch measured is shown; the iPhone's own step count is not mixed in.",
        "Nothing here is a diagnosis. A wrist sensor is not a medical device.",
    ]

    private func load() async {
        summary = await coordinator.trends.storeSummary()
        coverage = await coordinator.trends.heartRateCoverageToday()
    }

    private func export() async {
        exporting = true
        exportURL = await coordinator.trends.exportCSV(days: exportWindow.rawValue)
        exporting = false
    }
}
