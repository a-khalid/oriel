import AppKit

/// The interface language, chosen in Settings. Stored in the app's own defaults, so it takes effect on the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, arabic

    var id: Self { self }

    static var current: AppLanguage {
        let languages = UserDefaults.standard.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String]
        switch languages?.first {
        case "ar": return .arabic
        case "en": return .english
        default: return .system
        }
    }

    func apply() {
        let defaults = UserDefaults.standard
        switch self {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english:
            defaults.set(["en"], forKey: "AppleLanguages")
        case .arabic:
            defaults.set(["ar"], forKey: "AppleLanguages")
        }
        // AppKit takes its layout direction from the system language, not the app's. On an English Mac an Arabic
        // Oriel would keep a left-to-right window, so the flip is requested explicitly.
        if self == .arabic {
            defaults.set(true, forKey: "AppleTextDirection")
        } else {
            defaults.removeObject(forKey: "AppleTextDirection")
        }
    }

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "org.oriel.Oriel" }

    /// Quits through the normal path (running machines are suspended first) and opens Oriel again once it has exited.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
