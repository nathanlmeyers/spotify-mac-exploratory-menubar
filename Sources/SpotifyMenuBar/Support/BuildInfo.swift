import Foundation

/// Which build is actually running.
///
/// Worth its own type because "the code on disk is not the code running" is a failure mode
/// this app has already hit: a login item pinned a DerivedData bundle by absolute path, so a
/// two-month-old debug build kept relaunching while every fix sat unused in newer bundles.
/// Nothing in the app said which build it was, so a 400k-line debug log couldn't answer it
/// either. Surfaced at startup in the log and in Settings so it's never a mystery again.
enum BuildInfo {
    static var bundlePath: String { Bundle.main.bundleURL.path }

    /// True when this bundle lives in Xcode's DerivedData — a throwaway build artifact
    /// that must never become a login item (macOS pins login items by absolute path).
    static var isTransientBuild: Bool { bundlePath.contains("/Developer/Xcode/DerivedData/") }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// The executable's modification time — the closest thing to "when was this compiled"
    /// available without threading a build-time constant through the build system.
    static var builtAt: Date? {
        guard let exe = Bundle.main.executableURL,
              let values = try? exe.resourceValues(forKeys: [.contentModificationDateKey])
        else { return nil }
        return values.contentModificationDate
    }

    /// e.g. "0.1.0, built 2026-07-29 14:12" — short enough for a Settings footer.
    static var shortSummary: String {
        var s = "v\(version)"
        if let at = builtAt {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            s += ", built \(f.string(from: at))"
        }
        if isTransientBuild { s += " (debug build)" }
        return s
    }

    /// One line for the top of every log, so any future log tells you what produced it.
    static func logStartupBanner() {
        DebugLog.log("=== launch: \(shortSummary) — \(bundlePath)")
    }
}
