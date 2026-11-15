import Foundation

/// Which backend the app talks to. Two copies of the app exist (ios/project.yml): `zone2` → prod and
/// `zone2 stg` → staging; each carries its server in Info.plist (`Zone2ServerURL`). The launch
/// argument `-ServerURL <url>` overrides it (UserDefaults picks launch arguments up) — UI tests, agent.
public enum AppEnvironment {
    public static let stagingURL = URL(string: "https://api-staging.zone2.day")!
    public static let prodURL = URL(string: "https://api.zone2.day")!

    public static func serverURL(
        defaults: UserDefaults = .standard,
        info: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        if let raw = defaults.string(forKey: "ServerURL"), let url = URL(string: raw) {
            return url
        }
        if let raw = info?["Zone2ServerURL"] as? String, raw.hasPrefix("http"), let url = URL(string: raw) {
            return url
        }
        return stagingURL
    }

    /// Whether this copy puts the plan on the watch: the athlete's setting, else the copy's default
    /// (prod on, staging off — both copies on one watch would schedule two plans).
    public static func watchDelivery(
        defaults: UserDefaults = .standard,
        info: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        if defaults.object(forKey: watchDeliveryKey) != nil { return defaults.bool(forKey: watchDeliveryKey) }
        switch info?["Zone2WatchDeliveryDefault"] {
        case let s as String: return s == "YES" || s == "true" || s == "1"
        case let b as Bool: return b
        default: return true
        }
    }

    public static let watchDeliveryKey = "watchDelivery"
}
