import Foundation

/// Which backend the app talks to. Overridable with the launch argument `-ServerURL <url>`
/// (UserDefaults picks launch arguments up automatically) — used by UI tests and the agent.
public enum AppEnvironment {
    public static let stagingURL = URL(string: "https://api-staging.zone2.day")!
    public static let prodURL = URL(string: "https://api.zone2.day")!

    public static func serverURL(defaults: UserDefaults = .standard) -> URL {
        if let raw = defaults.string(forKey: "ServerURL"), let url = URL(string: raw) {
            return url
        }
        return stagingURL
    }
}
