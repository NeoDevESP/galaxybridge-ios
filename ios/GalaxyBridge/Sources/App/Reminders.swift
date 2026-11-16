import Foundation
import UserNotifications

/// Local reminders: water through the day, the planned workout, the morning
/// check-in, bedtime, and the end of a fast. Everything is scheduled on this
/// iPhone; nothing leaves it.
enum Reminders {

    struct Settings: Codable, Equatable {
        var water = false
        var waterEveryHours = 2
        var waterFrom = 9
        var waterTo = 21
        var workout = false
        var workoutHour = 18
        var workoutMinute = 0
        var morning = false
        var morningHour = 8
        var morningMinute = 30
        var bedtime = false
        var bedtimeHour = 23
        var bedtimeMinute = 0
        var fasting = true
    }

    private static let key = "reminders.settings"

    static var settings: Settings {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let value = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    /// Asks once; returns whether notifications are allowed.
    @discardableResult
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    /// Rebuilds every repeating reminder from the settings and the weekly plan.
    @MainActor
    static func reschedule(fitness: FitnessStore) {
        let center = UNUserNotificationCenter.current()
        let s = settings
        // Every id this function can create, cleared before adding afresh.
        let all = (0...23).map { "gb.water.\($0)" } + (1...7).map { "gb.workout.\($0)" } + ["gb.morning", "gb.bedtime"]
        center.removePendingNotificationRequests(withIdentifiers: all)

        var requests: [UNNotificationRequest] = []
        if s.water {
            var hour = s.waterFrom
            while hour <= s.waterTo {
                requests.append(daily(
                    id: "gb.water.\(hour)", hour: hour, minute: 0,
                    title: tr("Time for some water"),
                    body: tr("A glass now keeps you on track for today's water goal.")
                ))
                hour += max(1, s.waterEveryHours)
            }
        }
        if s.workout {
            for weekday in 1...7 {
                guard let routine = fitness.plannedRoutine(weekday: weekday) else { continue }
                var date = DateComponents()
                date.weekday = weekday
                date.hour = s.workoutHour
                date.minute = s.workoutMinute
                requests.append(request(
                    id: "gb.workout.\(weekday)",
                    title: tr("Workout today"),
                    body: String(format: tr("%@ is on today's plan."), tr(routine.name)),
                    trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
                ))
            }
        }
        if s.morning {
            requests.append(daily(
                id: "gb.morning", hour: s.morningHour, minute: s.morningMinute,
                title: tr("Good morning"),
                body: tr("Your sleep and readiness for today are ready.")
            ))
        }
        if s.bedtime {
            requests.append(daily(
                id: "gb.bedtime", hour: s.bedtimeHour, minute: s.bedtimeMinute,
                title: tr("Time to wind down"),
                body: tr("Wear the watch to bed, with some battery left, to get your sleep stages.")
            ))
        }
        for request in requests { center.add(request) }
    }

    /// One notification at the moment the current fast reaches its goal.
    static func fastChanged(_ fast: Fast?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["gb.fast"])
        guard settings.fasting, let fast else { return }
        let goal = fast.start.addingTimeInterval(fast.goalHours * 3600)
        let seconds = goal.timeIntervalSinceNow
        guard seconds > 1 else { return }
        center.add(request(
            id: "gb.fast",
            title: tr("Fast complete"),
            body: String(format: tr("You reached your %ld-hour goal. Well done!"), Int(fast.goalHours)),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        ))
    }

    private static func daily(id: String, hour: Int, minute: Int, title: String, body: String) -> UNNotificationRequest {
        var date = DateComponents()
        date.hour = hour
        date.minute = minute
        return request(id: id, title: title, body: body,
                       trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: true))
    }

    private static func request(id: String, title: String, body: String, trigger: UNNotificationTrigger) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
