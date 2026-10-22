#if os(tvOS)
import SwiftUI

/// Siri Remote navigable, on-device diagnostics; no network or disk operations.
struct EpisodeReleaseDiagnosticsView: View {
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ReleaseDateDiagnosticStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Episode Release Dates")
                    .font(.largeTitle.bold())
                Text("Enable in Settings → Advanced → Diagnostics, then select an episode or hold Select on an episode card and choose Inspect Release Date. Only five inspected episodes are retained until the app closes.")
                    .font(.system(size: 23)).foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Button("Clear History") { store.clearHistory() }
                        .disabled(store.snapshots.isEmpty)
                    Button("Done") { dismiss() }
                }
                .buttonStyle(.bordered)
                .tint(accentColor)

                if !store.isEnabled {
                    Text("Release date diagnostics are disabled.")
                        .font(.system(size: 25))
                } else if store.snapshots.isEmpty {
                    Text("No episodes inspected. Open a series episode to capture one.")
                        .font(.system(size: 25))
                }
                ForEach(store.snapshots) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(item.showTitle) — S\(item.seasonNumber)E\(item.episodeNumber)")
                            .font(.system(size: 28, weight: .bold))
                        Text(item.episodeTitle).font(.system(size: 23))
                        row("Metadata provider", item.provider)
                        row("Original add-on", item.originalRelease)
                        row("TMDB", item.tmdbRelease)
                        row("Selected release", item.finalRelease)
                        row("Source", item.source)
                        row("Why", item.explanation)
                        row("Precision", item.precision)
                        row("UK release time", item.ukDateTime)
                        row("Release state", item.releaseState)
                        row("NEW EPISODE", item.badgeEligibility)
                        row("Cache / freshness", item.cacheStatus)
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .padding(70)
        }
        .background(Color.black.ignoresSafeArea())
        .onExitCommand { dismiss() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(label):").foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 21))
    }
}
#endif
