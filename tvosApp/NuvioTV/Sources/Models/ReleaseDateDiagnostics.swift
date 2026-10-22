import Foundation
import Combine

/// A deliberately short, memory-only record of a single episode the user inspected.
struct ReleaseDateDiagnosticSnapshot: Identifiable {
    let id: UUID
    let showTitle: String
    let episodeNumber: Int
    let seasonNumber: Int
    let episodeTitle: String
    let provider: String
    let originalRelease: String
    let tmdbRelease: String
    let finalRelease: String
    let source: String
    let explanation: String
    let precision: String
    let ukDateTime: String
    let releaseState: String
    let badgeEligibility: String
    let cacheStatus: String
}

@MainActor
final class ReleaseDateDiagnosticStore: ObservableObject {
    static let shared = ReleaseDateDiagnosticStore(
        isEnabled: ProfileSettings.current.bool(forKey: SettingsKey.releaseDateDiagnostics)
    )

    @Published private(set) var snapshots: [ReleaseDateDiagnosticSnapshot] = []
    private(set) var isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { clearHistory() }
    }

    func clearHistory() {
        snapshots.removeAll(keepingCapacity: false)
    }

    /// Never keep metadata objects, links, artwork or account information.
    /// Only called for an explicit episode selection or Inspect action.
    func record(
        showTitle: String,
        episode: NuvioVideo,
        originalRelease: String?,
        tmdbRelease: String?,
        provider: String,
        cacheStatus: String,
        now: Date = Date()
    ) {
        guard isEnabled else { return }
        func safe(_ value: String?, max: Int = 100) -> String {
            guard let value, !value.isEmpty else { return "Unknown" }
            let withoutLinks = value.replacingOccurrences(
                of: #"https?://[^\s]+"#, with: "[link withheld]", options: .regularExpression
            )
            // Never show URL query fragments or multiline provider strings.
            let noSecrets = withoutLinks.replacingOccurrences(
                of: #"(?i)(token|api[_-]?key|password|secret)\s*[=:]\s*\S+"#,
                with: "[sensitive value withheld]", options: .regularExpression
            )
            return String(noSecrets.replacingOccurrences(of: "\n", with: " ").prefix(max))
        }
        func releaseValue(_ value: String?) -> String {
            guard EpisodeReleasePolicy.precision(of: value) != .invalid else { return "Unknown" }
            return safe(value, max: 40)
        }
        let original = EpisodeReleasePolicy.precision(of: originalRelease) == .invalid ? nil : originalRelease
        let tmdb = EpisodeReleasePolicy.precision(of: tmdbRelease) == .invalid ? nil : tmdbRelease
        let chosen = EpisodeReleasePolicy.preferredRelease(primary: original, fallback: tmdb)
        let source: String
        let explanation: String
        if chosen == original, chosen != nil {
            source = "Original add-on metadata"
            explanation = tmdb == nil ? "Original release is valid; no TMDB date captured." : "Original release preferred by precision or equal-source priority."
        } else if chosen == tmdb, chosen != nil {
            source = "TMDB fallback"
            explanation = "Original date missing or less precise; TMDB fallback selected."
        } else {
            source = "Unknown"
            explanation = "No valid source date was captured."
        }
        // The displayed result is the real selected UI value, even if it differs
        // from the expected precedence; do not conceal disagreement.
        let actual = episode.released
        let precision = EpisodeReleasePolicy.precision(of: actual)
        let localUK: String
        if precision == .exact, let instant = EpisodeReleasePolicy.releaseDate(for: actual) {
            let fmt = DateFormatter()
            fmt.timeZone = TimeZone(identifier: "Europe/London")
            fmt.locale = Locale(identifier: "en_GB")
            fmt.dateFormat = "d MMMM yyyy 'at' HH:mm zzz"
            localUK = fmt.string(from: instant)
        } else if precision == .dateOnly {
            localUK = "Calendar day only: \(EpisodeReleasePolicy.localReleaseDay(actual) ?? "Unknown"); UK broadcast time unknown"
        } else if precision == .localTime {
            localUK = "Local time without a source timezone; UK conversion unverified"
        } else {
            localUK = "Unknown"
        }
        let state = EpisodeReleasePolicy.releaseState(actual, now: now)
        let badge = precision == .exact &&
            EpisodeReleasePolicy.isRecentlyReleased(actual, within: EpisodeReleasePolicy.newEpisodeWindowDays, now: now)
                ? "Time-eligible; requires Next Up and qualifying watch history"
                : "Not eligible from this release value"
        let record = ReleaseDateDiagnosticSnapshot(
            id: UUID(),
            showTitle: safe(showTitle), episodeNumber: episode.episode, seasonNumber: episode.season,
            episodeTitle: safe(episode.title), provider: safe(provider),
            originalRelease: releaseValue(originalRelease), tmdbRelease: releaseValue(tmdbRelease),
            finalRelease: releaseValue(actual),
            source: source,
            explanation: safe(explanation, max: 160) + (chosen != actual ? " Selected UI value differs from expected source precedence." : ""),
            precision: precision.rawValue, ukDateTime: localUK,
            releaseState: state.rawValue, badgeEligibility: badge, cacheStatus: safe(cacheStatus)
        )
        snapshots.removeAll { $0.showTitle == record.showTitle && $0.seasonNumber == record.seasonNumber && $0.episodeNumber == record.episodeNumber }
        snapshots.insert(record, at: 0)
        if snapshots.count > 5 { snapshots.removeLast(snapshots.count - 5) }
    }
}
