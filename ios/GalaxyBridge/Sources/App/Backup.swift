import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Keeping the user's history safe on a sideloaded app.
///
/// Everything the app knows lives in its own container: the health database
/// and the fitness file. A sideloaded app can lose that container (an install
/// under another account, an expired signature that ends in a reinstall), so
/// a backup has to leave it. iCloud needs an entitlement a free signature does
/// not get, so the backup is a folder the user saves in Files (iCloud Drive or
/// On My iPhone) and can pick again to restore.
///
/// Restoring replaces the files while nothing has them open: they are staged
/// next to the live ones and swapped in at the next launch, before any store
/// opens them.
enum Backup {

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static let files = ["health.sqlite", "fitness.json"]
    private static let lastKey = "backup.last"

    static var lastBackup: Date? {
        let t = UserDefaults.standard.double(forKey: lastKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    // MARK: - Backup

    /// A consistent snapshot of the database (SQLite's VACUUM INTO, safe while
    /// the app keeps writing) plus the fitness file, as a folder.
    static func makeFolder(store: LocalHealthStore) async throws -> FileWrapper {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let db = temp.appendingPathComponent("health.sqlite")
        try await store.snapshot(to: db)
        var wrappers: [String: FileWrapper] = [
            "health.sqlite": FileWrapper(regularFileWithContents: try Data(contentsOf: db)),
        ]
        let fitness = support.appendingPathComponent("fitness.json")
        if let data = try? Data(contentsOf: fitness) {
            wrappers["fitness.json"] = FileWrapper(regularFileWithContents: data)
        }
        let info = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        wrappers["README.txt"] = FileWrapper(regularFileWithContents: Data(
            "GalaxyBridge backup, \(Date().formatted()), app \(info).\nRestore it from Settings > Backup > Restore a backup.\n".utf8
        ))
        return FileWrapper(directoryWithFileWrappers: wrappers)
    }

    static func markDone() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        Breadcrumbs.drop("backup: saved")
        scheduleReminder()
    }

    // MARK: - Restore

    enum RestoreError: LocalizedError {
        case notABackup
        var errorDescription: String? { tr("That folder is not a GalaxyBridge backup.") }
    }

    /// Copies a chosen backup folder next to the live files; it replaces them
    /// at the next launch.
    static func stageRestore(from folder: URL) throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let db = folder.appendingPathComponent("health.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else { throw RestoreError.notABackup }
        for name in files {
            let source = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let staged = support.appendingPathComponent(name + ".restore")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
        }
        Breadcrumbs.drop("backup: restore staged, applies on next launch")
    }

    /// Call at launch, before anything opens the stores. The current files are
    /// kept with a ".before-restore" suffix, in case the backup was the wrong one.
    static func applyPendingRestore() {
        let fm = FileManager.default
        for name in files {
            let staged = support.appendingPathComponent(name + ".restore")
            guard fm.fileExists(atPath: staged.path) else { continue }
            let live = support.appendingPathComponent(name)
            let previous = support.appendingPathComponent(name + ".before-restore")
            try? fm.removeItem(at: previous)
            if fm.fileExists(atPath: live.path) { try? fm.moveItem(at: live, to: previous) }
            // The database's write-ahead files belong to the old one.
            for suffix in ["-wal", "-shm"] {
                try? fm.removeItem(at: support.appendingPathComponent(name + suffix))
            }
            try? fm.moveItem(at: staged, to: live)
            Breadcrumbs.drop("backup: restored \(name)")
        }
    }

    // MARK: - Reminders

    /// A nudge a week after the last backup.
    static func scheduleReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["backup.reminder"])
        let content = UNMutableNotificationContent()
        content.title = tr("Back up GalaxyBridge")
        content.body = tr("A week since the last backup. It takes a few seconds: Settings > Backup.")
        let base = lastBackup ?? Date()
        let at = max(base.addingTimeInterval(7 * 86_400), Date().addingTimeInterval(3_600))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: "backup.reminder", content: content, trigger: trigger))
    }
}

/// When this install's signature runs out. SideStore and AltStore sign for
/// seven days; past that iOS refuses to open the app until it is refreshed.
enum Signature {

    static let expiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>", range: start.upperBound..<text.endIndex)
        else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let data = xml.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    /// Reminds two days ahead to refresh in SideStore.
    static func scheduleReminder() {
        guard let expiry else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["signature.reminder"])
        let at = expiry.addingTimeInterval(-2 * 86_400)
        guard at > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = tr("Refresh GalaxyBridge in SideStore")
        content.body = tr("Its signature runs out in two days; after that it will not open until refreshed.")
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: "signature.reminder", content: content, trigger: trigger))
    }
}

/// The backup folder as a document for `fileExporter`.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    let wrapper: FileWrapper

    init(wrapper: FileWrapper) { self.wrapper = wrapper }

    init(configuration: ReadConfiguration) throws {
        wrapper = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { wrapper }
}

/// Settings section: signature, backup, restore.
struct BackupSection: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var working = false
    @State private var message: String?
    @State private var restored = false
    @State private var confirmRestore: URL?

    var body: some View {
        Section {
            if let expiry = Signature.expiry {
                let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
                LabeledContent("Signature valid until") {
                    Text(expiry.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(days <= 2 ? .orange : .secondary)
                }
                if days <= 2 {
                    Text("Refresh it in SideStore soon, or the app will not open.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("Last backup") {
                Text(Backup.lastBackup.map { $0.formatted(.relative(presentation: .named)) } ?? tr("Never"))
                    .foregroundStyle(Backup.lastBackup == nil ? .orange : .secondary)
            }
            Button {
                Task {
                    working = true
                    defer { working = false }
                    do {
                        document = BackupDocument(wrapper: try await Backup.makeFolder(store: coordinator.store))
                        exporting = true
                    } catch {
                        message = error.localizedDescription
                    }
                }
            } label: {
                Label(working ? tr("Preparing…") : tr("Back up now"), systemImage: "externaldrive.badge.plus")
            }
            .disabled(working)
            Button {
                importing = true
            } label: {
                Label("Restore a backup", systemImage: "clock.arrow.circlepath")
            }
            if restored {
                Button("Close the app to finish restoring") { exit(0) }
                    .foregroundStyle(.orange)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Saves your health history, workouts, routines and nutrition as a folder in Files (iCloud Drive or On My iPhone). Keep it outside this app: if the app is ever reinstalled, its own files go with it.")
        }
        .fileExporter(
            isPresented: $exporting,
            document: document,
            contentType: .folder,
            defaultFilename: "GalaxyBridge-backup-" + Date().formatted(.iso8601.year().month().day())
        ) { result in
            switch result {
            case .success:
                Backup.markDone()
                message = tr("Backup saved.")
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { confirmRestore = url }
        }
        .alert(
            "Replace everything with this backup?",
            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })
        ) {
            Button("Restore", role: .destructive) {
                guard let url = confirmRestore else { return }
                do {
                    try Backup.stageRestore(from: url)
                    restored = true
                    message = tr("Ready. Close the app; it restores when it opens again.")
                } catch {
                    message = error.localizedDescription
                }
                confirmRestore = nil
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("Your current data is kept aside as a copy, but the app will show the backup's data from now on.")
        }
    }
}
