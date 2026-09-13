import Foundation

/// Remembers, per target app (by bundle identifier), which text-injection
/// method last succeeded — so `TextInjector` can skip straight to the
/// working method instead of re-attempting AX injection on every delivery
/// for apps (like VS Code) where it's known to reliably fail.
enum InjectionMethod: String {
    case ax
    case paste
    case clipboard
}

final class InjectionProfileStore {
    static let shared = InjectionProfileStore()

    private static let defaultsKey = "com.nodio.app.injectionProfiles"
    private let queue = DispatchQueue(label: "com.nodio.app.injectionProfileStore")

    private init() {}

    func method(for bundleID: String) -> InjectionMethod? {
        queue.sync {
            let profiles = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String]
            return profiles?[bundleID].flatMap(InjectionMethod.init(rawValue:))
        }
    }

    func record(_ method: InjectionMethod, for bundleID: String) {
        queue.sync {
            var profiles = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
            profiles[bundleID] = method.rawValue
            UserDefaults.standard.set(profiles, forKey: Self.defaultsKey)
        }
    }

    /// Clears all learned profiles — useful if a fix changes AX behavior and
    /// stale "paste-only" profiles would otherwise skip a now-working path.
    func reset() {
        queue.sync {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
    }
}
