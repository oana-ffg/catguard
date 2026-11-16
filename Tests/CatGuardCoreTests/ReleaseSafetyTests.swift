import Foundation
import Testing
@testable import CatGuardCore

@Suite("Release migration and update safety")
struct ReleaseSafetyTests {
    @Test func defaultsMigration() throws {
        let suite = "CatGuardMigrationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "circleEnabled")
        LegacySettingsMigration.migrate(defaults: defaults, legacy: [
            "circleEnabled": false, "didShowFirstLaunchSettings": true, "unrelated": "ignored"
        ])
        #expect(defaults.bool(forKey: "circleEnabled"))
        #expect(defaults.bool(forKey: "didShowFirstLaunchSettings"))
        #expect(defaults.object(forKey: "unrelated") == nil)
        defaults.set(false, forKey: "didShowFirstLaunchSettings")
        LegacySettingsMigration.migrate(defaults: defaults, legacy: ["didShowFirstLaunchSettings": true])
        #expect(!defaults.bool(forKey: "didShowFirstLaunchSettings"))
    }

    @Test func disabledLegacySettingIsCopied() throws {
        let suite = "CatGuardMigrationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LegacySettingsMigration.migrate(defaults: defaults, legacy: ["circleEnabled": false])
        #expect(defaults.object(forKey: "circleEnabled") != nil)
        #expect(!defaults.bool(forKey: "circleEnabled"))
    }

    @Test func rescuePhraseIsPreserved() throws {
        var writes: [String] = []
        let phrase = try RescuePhraseLoader.load(read: { "originalphrase" }, write: { writes.append($0) })
        #expect(phrase.value == "originalphrase")
        #expect(writes.isEmpty)
    }

    @Test func deniedReadAndInvalidPhraseNeverWriteDefaults() {
        enum Denied: Error { case denied }
        var writes: [String] = []
        #expect(throws: Denied.self) {
            try RescuePhraseLoader.load(read: { throw Denied.denied }, write: { writes.append($0) })
        }
        #expect(throws: RescuePhraseLoader.LoadError.self) {
            try RescuePhraseLoader.load(read: { "invalid 123" }, write: { writes.append($0) })
        }
        #expect(writes.isEmpty)
    }

    @Test func freshInstallWritesDefaultAndWriteFailurePropagates() throws {
        enum Denied: Error { case denied }
        var writes: [String] = []
        #expect(try RescuePhraseLoader.load(read: { nil }, write: { writes.append($0) }) == .default)
        #expect(writes == [RescuePhrase.default.value])
        #expect(throws: Denied.self) {
            try RescuePhraseLoader.load(read: { nil }, write: { _ in throw Denied.denied })
        }
    }

    @MainActor @Test func updaterWaitsForInactiveProtectionAndKnownFocus() {
        let gate = UpdateInstallationGate()
        var installs = 0
        gate.deferInstallation { installs += 1 }
        gate.resumeIfSafe()
        #expect(installs == 0) // startup Focus has not been read yet
        gate.focusStateKnown = true
        var reasons = GuardActivationReasons()
        _ = reasons.latchManualArm()
        gate.protectionRequested = reasons.shouldGuard
        gate.resumeIfSafe()
        #expect(gate.shouldDeferTermination)
        #expect(installs == 0)
        _ = reasons.setFocusActive(true)
        _ = reasons.clearManualArm() // Focus bypass is still protection intent
        gate.protectionRequested = reasons.shouldGuard
        gate.resumeIfSafe()
        #expect(installs == 0)
        _ = reasons.setFocusActive(false)
        gate.protectionRequested = reasons.shouldGuard
        gate.resumeIfSafe()
        gate.resumeIfSafe()
        #expect(installs == 1)
        // A new activation before termination must still cancel quitting.
        gate.protectionRequested = true
        #expect(gate.shouldDeferTermination)
        // An aborted Sparkle driver is not proof that its separate installer
        // has stopped. A staged update keeps the quit safeguard for this run.
        gate.markInstallationPending()
        #expect(gate.shouldDeferTermination)
        gate.protectionRequested = false
        #expect(!gate.shouldDeferTermination)
    }
}

@MainActor @Test func focusFailureBackoffIsBoundedAndResets() async {
    enum Unavailable: Error { case unavailable }
    var time: TimeInterval = 0
    var attempts = 0
    let monitor = FocusStateMonitor(now: { time }, query: {
        attempts += 1
        throw Unavailable.unavailable
    }, onUpdate: { _ in })
    monitor.start()
    for delay: TimeInterval in [2, 4, 8, 16, 32, 64, 128, 256, 300, 300] {
        await monitor.refreshIfNeeded()
        #expect(monitor.nextRefreshDelay == delay)
        time += delay
    }
    #expect(attempts == 10)
    monitor.receive(false)
    #expect(monitor.nextRefreshDelay == 300)
}
