import AppKit
import SwiftUI

/// About the app itself: version details for bug reports, links to the project, privacy, credits and the Sony
/// disclaimer. Deliberately names no individual; everything links to the public repository.
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                PageHeader(title: "About")
                AboutHero()
                AdaptiveColumns {
                    AboutDetailsCard()
                    AboutLinksCard()
                    Card("Privacy", symbol: "lock") {
                        AboutText("Open Sound Connect talks to your headphones directly over Bluetooth on this Mac. There is no account, analytics or cloud service.",
                                  "Its only network request is the optional daily update check, which reads this project's latest release on GitHub and sends nothing about you or your headphones.",
                                  "Now Playing reads track details and artwork locally from macOS.")
                    }
                    Card("Credits", symbol: "heart") {
                        AboutText("Now Playing uses the bundled MediaRemote Adapter, under the BSD-3-Clause license.",
                                  "Protocol research benefited from the open-source SonyHeadphonesClient and SonyBridge projects.",
                                  "The headphone models are original Blender artwork.",
                                  "Independent, community-developed software. Not affiliated with or endorsed by Sony. Sony names and trademarks belong to their respective owners.")
                    }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

@MainActor
enum AppInfo {
    static let project = URL(string: "https://github.com/\(UpdateChecker.repository)")!
    private static let info = Bundle.main.infoDictionary ?? [:]
    static let version = info["CFBundleShortVersionString"] as? String ?? "dev"
    static let build = info["CFBundleVersion"] as? String ?? "dev"
    static let system: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
    }()
    static let architecture: String = {
        #if arch(arm64)
        "Apple Silicon"
        #else
        "Intel"
        #endif
    }()
    /// One line to paste into a bug report.
    static var summary: String { "Open Sound Connect \(version) (\(build)) · \(system) · \(architecture)" }
}

private struct AboutHero: View {
    var body: some View {
        HStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Open Sound Connect").font(.heroTitle).foregroundStyle(Theme.text)
                Text("Version \(AppInfo.version)").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondary)
                Text("Your Sony headphones, at home on your Mac.").font(.body15).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

private struct AboutDetailsCard: View {
    @State private var copied = false

    var body: some View {
        Card("This Copy", symbol: "info.circle") {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    row("Version", AppInfo.version)
                    row("Build", AppInfo.build)
                    row("System", "\(AppInfo.system) · \(AppInfo.architecture)")
                    row("License", "MIT, free and open source")
                }
                Button(copied ? "Copied" : "Copy Version Info") { copy() }
                    .controlSize(.small)
                    .help("Copies one line with the version, build and system, for bug reports.")
            }
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).font(.label).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                .textSelection(.enabled)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppInfo.summary, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct AboutLinksCard: View {
    var body: some View {
        Card("Links", symbol: "link") {
            VStack(alignment: .leading, spacing: 10) {
                link("Project on GitHub", symbol: "chevron.left.forwardslash.chevron.right", AppInfo.project)
                link("Release Notes", symbol: "doc.text", AppInfo.project.appendingPathComponent("releases/tag/v\(AppInfo.version)"))
                link("All Releases", symbol: "shippingbox", AppInfo.project.appendingPathComponent("releases"))
                link("Report an Issue", symbol: "exclamationmark.bubble", AppInfo.project.appendingPathComponent("issues/new"))
                link("License", symbol: "checkmark.shield", AppInfo.project.appendingPathComponent("blob/main/LICENSE"))
            }
        }
    }

    private func link(_ title: String, symbol: String, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
            }
            .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.accent)
        .help(url.absoluteString)
    }
}

private struct AboutText: View {
    let paragraphs: [String]

    init(_ paragraphs: String...) { self.paragraphs = paragraphs }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(paragraphs, id: \.self) { Text($0) }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
