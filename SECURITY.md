# Security and threat model

CatGuard's adversary is a cat.

It reduces accidental keyboard and pointer input from paws while a Mac remains
unlocked. It is not an access-control, authentication, anti-malware,
anti-tampering, surveillance, or human-security product. A person with access to
the Mac can disable the Focus, quit the app, unplug a device, or otherwise bypass
CatGuard. Use the macOS lock screen for protection against people.

Input Monitoring and Accessibility are powerful, system-wide permissions. A
malicious build could observe keystrokes across applications or interfere with
input. CatGuard therefore publishes no prebuilt binary and recommends inspecting
and building the source under an identity controlled by the user. The app does
not install a privileged helper, daemon, kernel extension, or system extension.

Reports about persisted or transmitted input, an incorrect physical-event
classifier, unintended suppression outside guarded state, synthetic Computer Use
being blocked, or physical input remaining suppressed after process exit are
security-relevant and should be submitted privately through
[GitHub's security advisory form](https://github.com/oana-ffg/catguard/security/advisories/new).

Ordinary feline bypasses, imperfect circle recognition, visible cursor movement,
and a human being able to quit CatGuard are part of the stated threat model, not
security vulnerabilities.
