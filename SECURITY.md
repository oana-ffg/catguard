# Security and threat model

CatGuard's adversary is a cat.

It reduces accidental keyboard and pointer input from paws while a Mac remains
unlocked. It is not an access-control, authentication, anti-malware,
anti-tampering, surveillance, or human-security product. A person with access to
the Mac can disable the Focus, quit the app, unplug a device, or otherwise bypass
CatGuard. Use the macOS lock screen for protection against people.

The root helper is nevertheless treated as a real privilege boundary. It accepts
only a same-team signed CatGuard client and exposes no arbitrary execution or
filesystem operations. Reports about helper authentication, XPC validation,
unintended device selection, or input that can remain seized after watchdog
expiry are security-relevant and should be submitted privately through
[GitHub's security advisory form](https://github.com/oana-ffg/catguard/security/advisories/new).

Ordinary feline bypasses, imperfect circle recognition, visible cursor movement,
and a human being able to quit CatGuard are part of the stated threat model, not
security vulnerabilities.
