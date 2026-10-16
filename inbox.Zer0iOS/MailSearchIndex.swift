import Foundation
import GRDB

/// A private, on-device full-text index for the local mailbox cache.
///
/// Gmail remains the freshness source, but normal searches use this FTS5 index
/// first so the UI does not rescan every message body or depend on the network.
final class MailSearchIndex: @unchecked Sendable {
    private let database: DatabaseQueue?

    init() {
        do {
            let fileManager = FileManager.default
            let directory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("inbox.Zer0", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("mail-search.sqlite")
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { database in
                try database.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS mail_search USING fts5(
                        message_id UNINDEXED,
                        sender_name,
                        sender_alias,
                        sender_address,
                        subject,
                        content,
                        tokenize = 'unicode61 remove_diacritics 2'
                    )
                    """)
            }
            try? (url as NSURL).setResourceValue(
                URLFileProtection.completeUntilFirstUserAuthentication,
                forKey: .fileProtectionKey
            )
            database = queue
        } catch {
            // Search remains functional through deterministic in-memory ranking.
            // A protected or temporarily unavailable index must never block mail.
            database = nil
        }
    }

    func replace(with messages: [InboxMessage]) {
        guard let database else { return }
        try? database.write { database in
            try database.inTransaction {
                try database.execute(sql: "DELETE FROM mail_search")
                for message in messages {
                    try database.execute(
                        sql: """
                            INSERT INTO mail_search(
                                message_id, sender_name, sender_alias,
                                sender_address, subject, content
                            ) VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            message.id,
                            message.senderName,
                            message.senderAlias,
                            message.senderAddress,
                            message.subject,
                            message.searchableText
                        ]
                    )
                }
                return .commit
            }
        }
    }

    /// Returns nil when FTS has no useful match. Callers then use the complete
    /// in-memory set, which preserves typo-tolerant sender matching and avoids a
    /// stale or partial index hiding a valid result.
    func matchingIDs(for terms: [String], limit: Int = 500) -> Set<String>? {
        guard let database, !terms.isEmpty else { return nil }
        let expression = terms
            .map(ftsToken)
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " AND ")
        guard !expression.isEmpty else { return nil }

        let ids = try? database.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT message_id
                    FROM mail_search
                    WHERE mail_search MATCH ?
                    ORDER BY bm25(mail_search)
                    LIMIT ?
                    """,
                arguments: [expression, limit]
            )
        }
        guard let ids, !ids.isEmpty else { return nil }
        return Set(ids)
    }

    private func ftsToken(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "")
    }
}
