import Foundation

/// Copies only app-owned preferences, preserving newer values and the legacy domain.
/// Keychain remains at its original service; no secret is copied through defaults.
enum LegacySettingsMigration {
    static let legacyDomain = "com.oanaffg.CatGuard"
    private static let marker = "didMigrateLegacySettings"

    static func migrate(defaults: UserDefaults, legacy: [String: Any]) {
        guard !defaults.bool(forKey: marker) else { return }
        for key in ["circleEnabled", "didShowFirstLaunchSettings"] {
            if defaults.object(forKey: key) == nil, let value = legacy[key] as? Bool {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }
}
