import Foundation

/// Copies only app-owned preferences, preserving newer values and the legacy domain.
/// Keychain remains at its original service; no secret is copied through defaults.
/// The first-launch flag is not copied: notification authorization is per bundle
/// ID, and the new identity needs its first-launch Settings window for re-granting.
enum LegacySettingsMigration {
    static let legacyDomain = "com.oanaffg.CatGuard"
    private static let marker = "didMigrateLegacySettings"

    static func migrate(defaults: UserDefaults, legacy: [String: Any]) {
        guard !defaults.bool(forKey: marker) else { return }
        let key = "circleEnabled"
        if defaults.object(forKey: key) == nil, let value = legacy[key] as? Bool {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: marker)
    }
}
