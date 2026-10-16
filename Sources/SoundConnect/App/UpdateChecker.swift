import AppKit
import Foundation
import Observation

/// Looks for a newer published release on GitHub. It only reads the public "latest release" endpoint (no account,
/// no identifiers) and never installs anything itself: downloads happen on the release's GitHub page.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        /// The release's GitHub page, which lists the archives for each architecture.
        let pageURL: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), failed(String)
    }

    static let repository = "rolottr/open-sound-connect"
    private static let interval: TimeInterval = 24 * 60 * 60

    private enum Key {
        static let automatic = "updateChecksAutomatically"
        static let lastChecked = "updateLastChecked"
        static let skipped = "updateSkippedVersion"
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private(set) var state: State = .idle
    private(set) var lastChecked = UserDefaults.standard.object(forKey: Key.lastChecked) as? Date
    /// Hidden from the in-window offer for this run only ("Later").
    private(set) var offerDismissed = false
    private(set) var skippedVersion = UserDefaults.standard.string(forKey: Key.skipped)
    private var schedule: Task<Void, Never>?

    var checksAutomatically = UserDefaults.standard.object(forKey: Key.automatic) as? Bool ?? true {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Key.automatic) }
    }

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// The release to offer unprompted: not skipped and not put off for later.
    var offered: Release? {
        guard let release = available, !offerDismissed,
              release.version != skippedVersion else { return nil }
        return release
    }

    /// Checks shortly after launch, then hourly whether a day has passed, since the app can run for weeks in the
    /// menu bar.
    func startAutomaticChecks() {
        guard schedule == nil, !LaunchContext.isDeveloperRun else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private func checkIfDue() async {
        guard checksAutomatically, state != .checking else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        await check()
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("SoundConnect/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try Self.release(from: data)
            state = Self.isVersion(release.version, newerThan: currentVersion) ? .available(release) : .upToDate
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Key.lastChecked)
        } catch {
            state = .failed("Couldn’t reach GitHub. Check your connection and try again.")
        }
    }

    /// "Check for Updates…" from the app menu: always answers, in an alert.
    func checkAndReport() async {
        await check()
        let alert = NSAlert()
        switch state {
        case .available(let release):
            alert.messageText = "Sound Connect \(release.version) is available"
            alert.informativeText = "You have \(currentVersion). Download the new version from its GitHub release page, then replace the app in your Applications folder."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { download(release) }
        case .upToDate:
            alert.messageText = "You’re up to date"
            alert.informativeText = "Sound Connect \(currentVersion) is the latest version."
            alert.runModal()
        case .failed(let message):
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = message
            alert.runModal()
        case .idle, .checking:
            break
        }
    }

    /// Opens the release page on GitHub, where the person picks the archive for their Mac.
    func download(_ release: Release) {
        NSWorkspace.shared.open(release.pageURL)
    }

    func dismissOffer() { offerDismissed = true }

    func skip(_ release: Release) {
        skippedVersion = release.version
        UserDefaults.standard.set(release.version, forKey: Key.skipped)
    }

    // MARK: - Parsing

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: URL
        let draft: Bool
        let prerelease: Bool
    }

    static func release(from data: Data) throws -> Release {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { throw URLError(.cannotParseResponse) }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return Release(version: version, pageURL: release.htmlUrl)
    }

    /// Numeric, component-wise: 1.10.0 > 1.9.2, and 1.2 == 1.2.0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
