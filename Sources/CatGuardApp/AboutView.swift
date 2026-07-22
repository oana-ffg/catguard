import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)

            Text("CatGuard")
                .font(.largeTitle.bold())
            Text("Version \(version)")
                .foregroundStyle(.secondary)

            Text(
                "A tiny macOS menu-bar utility that blocks accidental physical input while your chosen Focus is active—because cats have impeccable timing."
            )
            .multilineTextAlignment(.center)

            Text(
                "Feline threat model only. CatGuard is not security against humans and is not a replacement for locking your Mac."
            )
            .font(.callout.weight(.semibold))
            .multilineTextAlignment(.center)

            Link(
                "github.com/oana-ffg/catguard",
                destination: URL(string: "https://github.com/oana-ffg/catguard")!
            )

            Text("Copyright © 2026 Oana Alina Goge · MIT License")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 460, height: 370)
    }
}
