import Foundation

struct ProtectedMessageStore {
    private var fileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inbox.Zer0", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("messages.json")
    }

    func load() throws -> [InboxMessage] {
        try JSONDecoder().decode([InboxMessage].self, from: Data(contentsOf: fileURL))
    }

    func save(_ messages: [InboxMessage]) throws {
        let data = try JSONEncoder().encode(messages)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
