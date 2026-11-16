import SwiftUI

/// Pairing, and the watch-install instructions that go with it.
///
/// The code entry used to be a plain `TextField` with a number pad, which on a
/// phone is a trap: the number pad has no return key, so the keyboard covered
/// the button that submits it and there was no way to dismiss it. Here each
/// digit is drawn as its own box over a hidden field, there is a Done button
/// above the keyboard, and the code is submitted automatically once the sixth
/// digit lands, so no button needs to be reachable at all.
struct PairingView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @FocusState private var editing: Bool
    @State private var digits = ""

    private var client: BridgeClient { coordinator.client }

    var body: some View {
        // Pushed from My Watch, inside that tab's navigation stack.
        List {
            codeSection
            stateSection
            discoverySection
            installSection
        }
        .navigationTitle("Pairing")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
        .task { coordinator.discovery.start() }
        .onDisappear { coordinator.discovery.stop() }
    
    }

    // MARK: - Code

    private var codeSection: some View {
        Section {
            VStack(spacing: 12) {
                Text("Enter the 6 digits shown on the watch")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ZStack {
                    // The real field, invisible and one point wide: it owns the
                    // keyboard while the boxes below show the value.
                    TextField("", text: Binding(
                        get: { digits },
                        set: { newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(6))
                            guard filtered != digits else { return }
                            digits = filtered
                            if filtered.count == 6 {
                                editing = false
                                client.setPairingCode(filtered)
                            }
                        }
                    ))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($editing)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)

                    HStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { index in
                            digitBox(at: index)
                        }
                    }
                    .onTapGesture { editing = true }
                }

                if digits.count == 6 {
                    Button("Use this code again") { client.setPairingCode(digits) }
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } footer: {
            Text("The code is on the watch's main screen, next to the key. Tap the boxes to type.")
        }
    }

    private func digitBox(at index: Int) -> some View {
        let characters = Array(digits)
        let filled = index < characters.count
        return Text(filled ? String(characters[index]) : " ")
            .font(.title2.monospacedDigit())
            .frame(width: 42, height: 54)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        editing && index == min(characters.count, 5) ? Color.accentColor : .clear,
                        lineWidth: 2
                    )
            )
    }

    // MARK: - State

    private var stateSection: some View {
        Section("State") {
            LabeledContent("Watch") {
                Text(client.isConnected ? "Connected" : (client.isScanning ? "Searching" : "Offline"))
                    .foregroundStyle(client.isConnected ? .green : .secondary)
            }
            if let fingerprint = client.keyFingerprint {
                LabeledContent("Key") { Text(fingerprint).monospaced() }
                Text("This must match the key on the watch. If it does not, the codes differ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let status = client.pairingStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = client.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            Button("Look for the watch again") { client.start() }
                .disabled(client.isConnected)

            Button("Forget this watch", role: .destructive) { client.forgetWatch() }

            Text("Pairing the watch in Settings is a different thing from this app finding it. Notifications and media work off that bond alone; health, contacts and calendar need this link.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Discovery

    private var discoverySection: some View {
        Section("Watch on this network") {
            if let error = coordinator.discovery.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if coordinator.discovery.endpoints.isEmpty {
                Text(
                    coordinator.discovery.isBrowsing
                        ? "Looking for wireless debugging. Turn it on in the watch's developer options."
                        : "Not looking."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(coordinator.discovery.endpoints) { endpoint in
                LabeledContent(endpoint.kind.label) {
                    Text(endpoint.display).monospaced().font(.footnote)
                }
            }
            Text("Found over Bonjour, so you do not have to read the address off the watch. These ports change every time wireless debugging restarts.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Installing on the watch

    private var installSection: some View {
        Section("Installing the watch app") {
            Text("The watch app is installed over ADB, and the iPhone cannot do that part: Android's pairing binds the 6-digit code to a TLS exporter value, and iOS exposes no TLS exporter. Use the tablet console, which finds the watch on its own and installs without typing an address.")
            .font(.caption)
            .foregroundStyle(.secondary)

            if let connect = coordinator.discovery.endpoints.first(where: { $0.kind == .connect }),
               let host = connect.host, let port = connect.port {
                LabeledContent("Tell the tablet") {
                    Text("\(host):\(port)").monospaced().font(.footnote)
                }
            }
        }
    }
}
