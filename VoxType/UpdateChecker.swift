import AppKit
import Foundation

/// Checks GitHub Releases for a newer Nodio version.
enum UpdateChecker {
    private static let api = URL(string: "https://api.github.com/repos/its-ash/Nodio/releases/latest")!
    private static let lastCheckKey = "com.nodio.app.lastUpdateCheck"
    private static let interval: TimeInterval = 24 * 3600

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Runs at most once per day. Only shows UI when an update exists.
    static func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > interval else { return }
        check(userInitiated: false)
    }

    static func check(userInitiated: Bool) {
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Nodio/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let release = ok ? data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) } : nil
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                guard let release, !release.draft, !release.prerelease else {
                    if userInitiated { alert("Cannot Check for Updates", err?.localizedDescription ?? "GitHub did not return a release.") }
                    return
                }
                let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if isNewer(latest, than: currentVersion) {
                    offer(latest, release.html_url)
                } else if userInitiated {
                    alert("Nodio Is Up to Date", "Version \(currentVersion) is the latest version.")
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func offer(_ version: String, _ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Nodio \(version) Is Available"
        a.informativeText = "You have version \(currentVersion). Download the new DMG from GitHub?"
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    private static func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
