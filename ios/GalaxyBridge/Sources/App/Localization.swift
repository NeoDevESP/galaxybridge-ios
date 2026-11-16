import Foundation

/// Translates a string built at run time (a model title, a computed label).
/// Literals in `Text`, `Label`, `Button` and friends are translated by SwiftUI
/// itself; this is for everything that reaches the screen as a plain String.
/// The English text is the key, so a missing translation shows English.
func tr(_ english: String) -> String {
    Bundle.main.localizedString(forKey: english, value: english, table: nil)
}

/// The app's language. "System" follows the iPhone; the others override it for
/// this app only, the same as Settings > GalaxyBridge > Language. iOS reads the
/// choice at launch, so a change applies after the app restarts.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    /// Shown in its own language, so anyone can find theirs.
    var title: String {
        switch self {
        case .system: return tr("System")
        case .english: return "English"
        case .spanish: return "Español"
        }
    }

    private static let key = "AppleLanguages"
    private static let chosenKey = "app.language"

    static var current: AppLanguage {
        get {
            UserDefaults.standard.string(forKey: chosenKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: chosenKey)
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: key)
            }
        }
    }

    /// The language the app is showing right now.
    static var active: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }
}

/// Translates text with numbers in it ("Walk 10,000 steps in one day") by
/// looking up the pattern with the numbers taken out ("Walk %@ steps in one
/// day") and putting them back.
func trNumbers(_ english: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"\d[\d,.]*\d|\d"#) else { return tr(english) }
    let text = english as NSString
    var key = ""
    var numbers: [String] = []
    var last = 0
    for match in regex.matches(in: english, range: NSRange(location: 0, length: text.length)) {
        key += text.substring(with: NSRange(location: last, length: match.range.location - last)) + "%@"
        numbers.append(text.substring(with: match.range))
        last = match.range.location + match.range.length
    }
    key += text.substring(from: last)
    guard !numbers.isEmpty else { return tr(english) }
    let translated = tr(key)
    guard translated != key else { return english }
    return String(format: translated, arguments: numbers.map { $0 as CVarArg })
}
