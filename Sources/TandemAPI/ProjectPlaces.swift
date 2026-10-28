import Foundation

/// What the app remembers about a project by its file's path: its place in
/// the recent list (the project list on the welcome window), and where its
/// timeline and window were. A rename moves all three to the new path, so
/// the project stays on the list and opens where it was.
///
/// It lives here, not in the app, because `tandem rename` does it too. The
/// app keeps the recent list in memory, so after writing these the command
/// posts `renamedNotification` and a running app reloads its list.
public enum ProjectPlaces {
    public static let appDomain = "com.mikerosoft.tandem"
    public static let recentKey = "recentProjects"
    public static let timelinesKey = "projectTimelines"
    public static let windowFramesKey = "projectWindowFrames"
    /// Posted (distributed) after a rename outside the app. The object is
    /// the defaults domain written, so an app on a test suite ignores it.
    public static let renamedNotification = Notification.Name("com.mikerosoft.tandem.projectRenamed")

    /// The app's defaults: its own domain, or `TANDEM_DEFAULTS_SUITE` (tests
    /// and isolated app builds use one, and so must the commands they run).
    public static func domain(environment: [String: String]) -> String {
        guard let suite = environment["TANDEM_DEFAULTS_SUITE"], !suite.isEmpty else { return appDomain }
        return suite
    }

    public static func defaults(environment: [String: String]) -> UserDefaults? {
        UserDefaults(suiteName: domain(environment: environment))
    }

    /// Moves what's remembered under `old` to `new`. A project that isn't on
    /// the recent list isn't added to it.
    public static func moved(from old: URL, to new: URL, in defaults: UserDefaults) {
        let from = old.standardizedFileURL.path
        let to = new.standardizedFileURL.path
        guard from != to else { return }
        if let paths = defaults.stringArray(forKey: recentKey), paths.contains(from) {
            defaults.set(replacing(from, with: to, in: paths), forKey: recentKey)
        }
        for key in [timelinesKey, windowFramesKey] {
            guard var all = defaults.dictionary(forKey: key), let saved = all.removeValue(forKey: from) else { continue }
            all[to] = saved
            defaults.set(all, forKey: key)
        }
    }

    /// `paths` with `old` swapped for `new` in the same place, and no other
    /// copy of `new`.
    public static func replacing(_ old: String, with new: String, in paths: [String]) -> [String] {
        guard let index = paths.firstIndex(of: old) else { return paths }
        var paths = paths
        paths[index] = new
        return paths.enumerated().filter { $0.offset == index || $0.element != new }.map(\.element)
    }
}
