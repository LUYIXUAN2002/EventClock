import Foundation

/// Single source for user-facing app metadata.
///
/// `version` is the Dota-style display version shown in the app. Apple's
/// distribution metadata stays numeric and independent (`MARKETING_VERSION`,
/// currently 1.1.0). The technical build comes from `CURRENT_PROJECT_VERSION`
/// / `CFBundleVersion`.
enum AppInfo {
    static let name = "EventClock"
    static let version = "1.02B"

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var displayVersion: String {
        "\(name) v\(version)"
    }
}
