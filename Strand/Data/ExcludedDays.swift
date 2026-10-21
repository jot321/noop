import Foundation

// MARK: - Excluded days (2026-10-21)
//
// Days the user marked "not me": someone else wore the strap, or the readings are junk. The engine
// skips them when scoring, leaves their nights out of every baseline, and removes the computed rows
// it wrote for them earlier. The raw strap data stays in the store, so removing a day from this list
// and rescoring brings it back. Stored as a sorted array of "yyyy-MM-dd" local day keys.

enum ExcludedDays {
    static let defaultsKey = "noop.excludedDays"
    /// Launch argument that adds days to the list, e.g. `--exclude-days 2026-08-02,2026-08-03`. Lets the
    /// Mac-side install script apply an exclusion without touching the phone's screen.
    static let launchArgument = "--exclude-days"

    static func current(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.stringArray(forKey: defaultsKey) ?? []).filter(isDayKey))
    }

    static func save(_ days: Set<String>, _ defaults: UserDefaults = .standard) {
        defaults.set(days.filter(isDayKey).sorted(), forKey: defaultsKey)
    }

    /// Adds `days` and returns true when the list changed.
    @discardableResult
    static func add(_ days: [String], _ defaults: UserDefaults = .standard) -> Bool {
        let before = current(defaults)
        let after = before.union(days.filter(isDayKey))
        guard after != before else { return false }
        save(after, defaults)
        return true
    }

    @discardableResult
    static func remove(_ day: String, _ defaults: UserDefaults = .standard) -> Bool {
        var days = current(defaults)
        guard days.remove(day) != nil else { return false }
        save(days, defaults)
        return true
    }

    /// The day keys passed after `--exclude-days` (comma-separated), or [] when the flag is absent.
    static func launchDays(_ arguments: [String]) -> [String] {
        guard let i = arguments.firstIndex(of: launchArgument), i + 1 < arguments.count else { return [] }
        return arguments[i + 1].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isDayKey)
    }

    /// Applies `--exclude-days` from this launch; true when the list changed (the caller rescores).
    static func applyLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments,
                                     _ defaults: UserDefaults = .standard) -> Bool {
        add(launchDays(arguments), defaults)
    }

    /// A real calendar date in "yyyy-MM-dd" form.
    static func isDayKey(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        return dayFormatter.date(from: s).map { dayFormatter.string(from: $0) == s } ?? false
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
