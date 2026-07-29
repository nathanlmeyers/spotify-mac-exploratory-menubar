import Foundation
import CoreGraphics

/// When the now-playing text accompanies the menu bar icon.
enum MenuBarTitleMode: String, CaseIterable, Identifiable {
    case never      // icon only, always
    case whenHeld   // icon only until discovery holds a song for review
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "Never"
        case .whenHeld: return "Only while a song is held"
        case .always: return "Always"
        }
    }
}

/// Composes the "Artist — Title" menu bar text and fits it to a **width in points**.
///
/// Measuring in characters cannot bound a proportional font: at the 13pt menu bar font the
/// same 45-character budget spans 141pt ("iiii…") to 562pt ("WWWW…"), and a realistic
/// artist+title runs ~300pt. On a notched Mac the status area that wide doesn't fit, and
/// macOS resolves that by hiding status items — so an over-long title made the whole app
/// invisible. Hence: measure, don't count.
///
/// `measure` is injected so this stays free of AppKit and can be unit-tested; the app passes
/// a closure backed by the status button's own font.
enum MenuBarTitle {
    static let separator = " — "
    static let ellipsis = "…"

    /// Selectable width budgets, in points. Roughly 13, 20, and 32 typical characters.
    static let widthOptions: [Double] = [100, 150, 240]
    static let defaultWidth: Double = 150

    /// "Artist — Title" fitted to `maxWidth`. The song title is what survives: the artist
    /// list is trimmed first, and only if the title alone still doesn't fit is it truncated.
    /// Returns "" when nothing meaningful fits.
    static func fitted(title rawTitle: String,
                       artists rawArtists: String,
                       maxWidth: CGFloat,
                       measure: (String) -> CGFloat) -> String {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artists = rawArtists.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxWidth > 0, !title.isEmpty else { return "" }

        if artists.isEmpty { return truncated(title, toWidth: maxWidth, measure: measure) }

        let full = artists + separator + title
        if measure(full) <= maxWidth { return full }

        // Give the artist whatever room the separator + full title leaves.
        let fittedArtists = truncated(artists,
                                      toWidth: maxWidth - measure(separator + title),
                                      measure: measure)
        if !fittedArtists.isEmpty { return fittedArtists + separator + title }

        // No room for even one artist character: show the title by itself.
        return truncated(title, toWidth: maxWidth, measure: measure)
    }

    /// The longest ellipsis-suffixed prefix of `s` that fits `maxWidth`, or `s` itself when it
    /// already fits. Empty when even the ellipsis alone is too wide.
    static func truncated(_ s: String,
                          toWidth maxWidth: CGFloat,
                          measure: (String) -> CGFloat) -> String {
        guard maxWidth > 0 else { return "" }
        if measure(s) <= maxWidth { return s }

        // Binary search the prefix length; widths are monotonic in prefix length.
        let chars = Array(s)
        var best = ""
        var lo = 0, hi = chars.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candidate = String(chars[0..<mid]) + ellipsis
            if measure(candidate) <= maxWidth {
                best = candidate
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }
}
