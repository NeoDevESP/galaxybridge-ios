import Foundation
import Network
import os

/// Finds the watch's wireless-debugging endpoints on the local network.
///
/// Android advertises them over Bonjour, so there is no need to read an IP and
/// a port off a watch screen and retype them:
///
///   - `_adb-tls-pairing._tcp` appears only while the pairing dialog is open,
///     and carries the port that goes with the 6-digit code.
///   - `_adb-tls-connect._tcp` is the debugging endpoint, advertised for as
///     long as wireless debugging is on.
///   - `_adb._tcp` is the legacy port-5555 service, which older watches use.
///
/// The ports change every time the service restarts, which is exactly why
/// discovering them beats writing them down.
@MainActor
final class DebugDiscovery: ObservableObject {

    struct Endpoint: Identifiable, Equatable {
        enum Kind: String {
            case pairing = "_adb-tls-pairing._tcp"
            case connect = "_adb-tls-connect._tcp"
            case legacy = "_adb._tcp"

            var label: String {
                switch self {
                case .pairing: return tr("Pairing")
                case .connect: return tr("Debugging")
                case .legacy: return tr("Legacy (5555)")
                }
            }
        }

        let kind: Kind
        let name: String
        var host: String?
        var port: UInt16?

        var id: String { kind.rawValue + "/" + name }

        var display: String {
            guard let host, let port else { return "resolving…" }
            return "\(host):\(port)"
        }
    }

    @Published private(set) var endpoints: [Endpoint] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var lastError: String?

    private var browsers: [NWBrowser] = []
    private var failures: Set<Endpoint.Kind> = []
    private var connections: [String: NWConnection] = [:]
    private let log = Logger(subsystem: "dev.galaxybridge.companion", category: "discovery")

    func start() {
        guard browsers.isEmpty else { return }
        isBrowsing = true
        lastError = nil
        failures.removeAll()
        for kind in [Endpoint.Kind.pairing, .connect, .legacy] {
            browse(kind)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        isBrowsing = false
    }

    private func browse(_ kind: Endpoint.Kind) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: kind.rawValue, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let error) = state {
                    // All three browsers fail together when the local-network
                    // permission is denied, and three copies of the same error
                    // read like three separate bugs. Say it once, and say what
                    // it does and does not break.
                    self.failures.insert(kind)
                    self.lastError = "Local network access is off, so the watch cannot be found automatically. Settings > GalaxyBridge > Local Network. This only affects finding the address; the Bluetooth link is unaffected."
                    self.log.error("browser failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.apply(kind: kind, results: results)
            }
        }

        browser.start(queue: .main)
        browsers.append(browser)
    }

    private func apply(kind: Endpoint.Kind, results: Set<NWBrowser.Result>) {
        var found: [Endpoint] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            found.append(Endpoint(kind: kind, name: name))
            resolve(result.endpoint, kind: kind, name: name)
        }
        // Keep whatever was already resolved for the entries that are still
        // advertised, drop the rest, and leave the other service types alone.
        let previous = endpoints
        endpoints = endpoints.filter { $0.kind != kind } + found.map { entry in
            var merged = entry
            if let old = previous.first(where: { $0.id == entry.id }) {
                merged.host = old.host
                merged.port = old.port
            }
            return merged
        }
        endpoints.sort { $0.kind.label < $1.kind.label }
    }

    /// Bonjour gives a name, not an address. A connection in `.preparing` is
    /// enough to learn the resolved host and port without sending anything.
    private func resolve(_ endpoint: NWEndpoint, kind: Endpoint.Kind, name: String) {
        let id = kind.rawValue + "/" + name
        guard connections[id] == nil else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready, .preparing:
                    if let remote = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = remote {
                        self.record(id: id, host: Self.text(for: host), port: port.rawValue)
                        connection.cancel()
                        self.connections[id] = nil
                    }
                case .failed, .cancelled:
                    self.connections[id] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func record(id: String, host: String, port: UInt16) {
        guard let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
        endpoints[index].host = host
        endpoints[index].port = port
        log.info("resolved \(id, privacy: .public) to \(host, privacy: .public):\(port)")
    }

    private static func text(for host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case .ipv6(let address):
            return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
