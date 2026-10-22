import Foundation
import CryptoKit

/// Best-effort catalog *presentation* only. Playback checkpoints, watched
/// history, Next Up, progress-source and episode release state never live here.
/// An exact account/profile/configuration match and TTL are mandatory.
enum TVHomePresentationCache {
    static let lifetime: TimeInterval = 12 * 60 * 60
    private static let directory = "homeCatalogPresentation"
    private static let schema = 1
    private static let maximumBytes = 2_000_000
    private static let maximumRows = 32
    private static let maximumItemsPerRow = 32
    private static let writer = Writer()

    private struct Row: Codable, Sendable {
        var id: String
        var title: String
        var items: [NuvioMeta]
        var contentType: String?
        var catalogId: String?
        var addonId: String?
        var addonName: String?
        var catalogGenre: String?
        var manifestURL: String?
        var manifestShowInHome: Bool?
        var posterShape: String?

        init(_ row: TVHomeSection) {
            id = row.id
            title = row.title
            items = Array(row.items.prefix(maximumItemsPerRow)).map(\.persistenceSnapshot)
            contentType = row.contentType
            catalogId = row.catalogId
            addonId = row.addonId
            addonName = row.addonName
            catalogGenre = row.catalogGenre
            manifestURL = row.manifestURL
            manifestShowInHome = row.manifestShowInHome
            posterShape = row.posterShape
        }

        func restore() -> TVHomeSection {
            TVHomeSection(
                id: id, title: title, items: items,
                contentType: contentType, catalogId: catalogId,
                addonId: addonId, addonName: addonName,
                catalogGenre: catalogGenre, manifestURL: manifestURL,
                manifestShowInHome: manifestShowInHome, posterShape: posterShape
            )
        }
    }

    private struct Snapshot: Codable, Sendable {
        let schema: Int
        let scope: String
        let configuration: String
        let storedAt: Date
        let rows: [Row]
    }

    private static func key(accountScope: String, profileID: String) -> String {
        // Deterministic digest prevents identifiers from appearing in filenames.
        let bytes = Data("home|\(accountScope)|\(profileID)".utf8)
        return "catalog-" + SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func restore(
        accountScope: String, profileID: String, configuration: String,
        now: Date = Date()
    ) -> [TVHomeSection]? {
        guard !accountScope.isEmpty, !profileID.isEmpty, !configuration.isEmpty else { return nil }
        let location = key(accountScope: accountScope, profileID: profileID)
        guard let bytes = LargePayloadStore.read(key: location, directory: directory),
              bytes.count <= maximumBytes,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: bytes),
              snapshot.schema == schema,
              snapshot.scope == location,
              snapshot.configuration == configuration,
              snapshot.storedAt <= now,
              now.timeIntervalSince(snapshot.storedAt) <= lifetime,
              !snapshot.rows.isEmpty,
              snapshot.rows.count <= maximumRows,
              snapshot.rows.allSatisfy({ !$0.items.isEmpty && $0.items.count <= maximumItemsPerRow })
        else { return nil }
        return snapshot.rows.map { $0.restore() }
    }

    static func store(
        rows: [TVHomeSection], accountScope: String, profileID: String,
        configuration: String, now: Date = Date()
    ) -> Bool {
        guard !accountScope.isEmpty, !profileID.isEmpty, !configuration.isEmpty else { return false }
        let location = key(accountScope: accountScope, profileID: profileID)
        let safeRows = rows.filter {
            !$0.isCollectionRow && !$0.isLoadingPlaceholder && !$0.items.isEmpty
        }.prefix(maximumRows).map(Row.init)
        guard !safeRows.isEmpty else { return false }
        let snapshot = Snapshot(schema: schema, scope: location,
                                configuration: configuration, storedAt: now, rows: safeRows)
        guard let bytes = try? JSONEncoder().encode(snapshot),
              bytes.count <= maximumBytes else { return false }
        return LargePayloadStore.write(bytes, key: location, directory: directory)
    }

    static func scheduleSave(
        rows: [TVHomeSection], accountScope: String, profileID: String,
        configuration: String
    ) {
        guard !accountScope.isEmpty, !profileID.isEmpty, !configuration.isEmpty else { return }
        let filtered = rows.filter { !$0.isCollectionRow && !$0.isLoadingPlaceholder && !$0.items.isEmpty }
            .prefix(maximumRows).map(Row.init)
        guard !filtered.isEmpty else { return }
        let location = key(accountScope: accountScope, profileID: profileID)
        let snapshot = Snapshot(schema: schema, scope: location,
                                configuration: configuration, storedAt: Date(), rows: filtered)
        Task { await writer.schedule(snapshot, for: location) }
    }

    static func remove(accountScope: String, profileID: String) {
        guard !accountScope.isEmpty, !profileID.isEmpty else { return }
        LargePayloadStore.remove(
            key: key(accountScope: accountScope, profileID: profileID),
            directory: directory
        )
    }

    private actor Writer {
        private var pending: [String: Task<Void, Never>] = [:]

        func schedule(_ snapshot: Snapshot, for key: String) {
            pending[key]?.cancel()
            pending[key] = Task {
                do { try await Task.sleep(for: .milliseconds(750)) }
                catch { return }
                guard !Task.isCancelled,
                      let bytes = try? JSONEncoder().encode(snapshot),
                      bytes.count <= maximumBytes else { return }
                _ = LargePayloadStore.write(bytes, key: key, directory: directory)
            }
        }
    }
}
