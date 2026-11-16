import Contacts
import EventKit
import Foundation
import os

/// Contacts and calendar, read on the phone and pushed to the watch.
///
/// The watch cannot read these itself, and iOS gives no equivalent of ANCS for
/// them, so this is the whole mechanism. Both syncs are deliberately
/// minimising: only name, numbers and emails leave the phone, only events in a
/// short forward window, and nothing is uploaded anywhere — the data goes over
/// the encrypted BLE link to one paired watch.
@MainActor
final class PimSync: ObservableObject {

    @Published private(set) var contactCount = 0
    @Published private(set) var eventCount = 0
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?

    private let contactStore = CNContactStore()
    private let eventStore = EKEventStore()
    private let log = Logger(subsystem: "dev.galaxybridge.companion", category: "pim")

    /// 200 contacts per page keeps each page inside a few BLE fragments.
    private let contactsPerPage = 50
    private let eventsPerPage = 100

    /// How far ahead the watch agenda needs to look.
    private let calendarWindow: TimeInterval = 14 * 24 * 60 * 60

    func syncContacts(using client: BridgeClient) async {
        do {
            let granted = try await contactStore.requestAccess(for: .contacts)
            guard granted else {
                lastError = "Contacts access denied"
                return
            }
        } catch {
            lastError = error.localizedDescription
            return
        }

        // The formatter's own descriptor is required: CNContactFormatter
        // reads middle names, prefixes, nicknames and more, and touching a
        // key that was not fetched raises an Objective-C exception that
        // closes the app. That was the crash on "Sync contacts and calendar".
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]

        // enumerateContacts is synchronous and walks the whole address book.
        // Run on the main actor, a few thousand contacts is enough of a stall
        // for the watchdog to kill the app, so it goes off it.
        let store = contactStore
        let contacts: [Contact]
        do {
            contacts = try await Task.detached(priority: .utility) { () throws -> [Contact] in
                var collected: [Contact] = []
                let request = CNContactFetchRequest(keysToFetch: keys)
                request.sortOrder = .familyName
                try store.enumerateContacts(with: request) { cnContact, _ in
                    // A contact with no name but a company still deserves to
                    // show up on the wrist, so fall back to the organisation.
                    let formatted = CNContactFormatter.string(from: cnContact, style: .fullName) ?? ""
                    let name = formatted.isEmpty ? cnContact.organizationName : formatted
                    guard !name.isEmpty else { return }
                    let phones = cnContact.phoneNumbers.map { $0.value.stringValue }
                    let emails = cnContact.emailAddresses.map { $0.value as String }
                    guard !phones.isEmpty || !emails.isEmpty else { return }
                    collected.append(
                        Contact(
                            id: cnContact.identifier,
                            name: name,
                            phones: phones,
                            emails: emails,
                            favourite: false
                        )
                    )
                }
                return collected
            }.value
        } catch {
            lastError = error.localizedDescription
            log.error("contact enumeration failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let revision = Int64(Date().timeIntervalSince1970)
        let pages = max(1, Int(ceil(Double(contacts.count) / Double(contactsPerPage))))
        for index in 0..<pages {
            let slice = Array(
                contacts[
                    (index * contactsPerPage)..<min((index + 1) * contactsPerPage, contacts.count)
                ]
            )
            let page = ContactPage(
                page: index,
                totalPages: pages,
                contacts: slice,
                revision: revision
            )
            client.send(.contacts, payload: BridgeCoder.encode(page))
        }

        contactCount = contacts.count
        lastSyncAt = Date()
        lastError = nil
        log.info("sent \(contacts.count, privacy: .public) contacts in \(pages, privacy: .public) page(s)")
    }

    func syncCalendar(using client: BridgeClient) async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            guard granted else {
                lastError = "Calendar access denied"
                return
            }
        } catch {
            lastError = error.localizedDescription
            return
        }

        let start = Calendar.current.startOfDay(for: Date())
        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: start.addingTimeInterval(calendarWindow),
            calendars: nil
        )
        // startDate, endDate and calendar are implicitly unwrapped in
        // EventKit and can be nil for a broken or half-synced event; one of
        // those must be skipped, not crash the app.
        let events: [CalendarEventDTO] = eventStore.events(matching: predicate)
            .compactMap { (event: EKEvent) -> CalendarEventDTO? in
                guard let startDate = event.startDate as Date?,
                      let endDate = event.endDate as Date? else { return nil }
                let calendarTitle: String? = (event.calendar as EKCalendar?)?.title
                let rawTitle: String = (event.title as String?) ?? ""
                return CalendarEventDTO(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: rawTitle.isEmpty ? "(no title)" : rawTitle,
                    location: event.location,
                    start: Int64(startDate.timeIntervalSince1970 * 1000),
                    end: Int64(endDate.timeIntervalSince1970 * 1000),
                    allDay: event.isAllDay,
                    calendarName: calendarTitle
                )
            }
            .sorted { $0.start < $1.start }

        let revision = Int64(Date().timeIntervalSince1970)
        let pages = max(1, Int(ceil(Double(events.count) / Double(eventsPerPage))))
        for index in 0..<pages {
            let slice = Array(
                events[(index * eventsPerPage)..<min((index + 1) * eventsPerPage, events.count)]
            )
            let page = CalendarPage(
                page: index,
                totalPages: pages,
                events: slice,
                revision: revision
            )
            client.send(.calendar, payload: BridgeCoder.encode(page))
        }

        eventCount = events.count
        lastSyncAt = Date()
        lastError = nil
        log.info("sent \(events.count, privacy: .public) events")
    }
}
