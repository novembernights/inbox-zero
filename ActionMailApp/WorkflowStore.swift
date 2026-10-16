import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class WorkflowStore {
    var threads: [WaitingThread]
    var isScanning = false
    var statusMessage = "Ready to connect to Mail"
    var lastScanAt: Date?

    @ObservationIgnored private let defaultsKey = "action-mail-threads-v1"
    @ObservationIgnored private let housekeepingKey = "action-mail-last-housekeeping-v1"
    @ObservationIgnored private let logger = Logger(subsystem: "org.example.inboxzero.desktop", category: "MailScan")

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([WaitingThread].self, from: data) {
            threads = saved
        } else {
            threads = []
        }
        performDailyHousekeepingIfNeeded()
    }

    func counts(for state: WorkflowState) -> Int {
        threads.count { $0.state == state && !$0.isArchived }
    }

    var archivedThreads: [WaitingThread] {
        threads.filter(\.isArchived).sorted {
            ($0.completedAt ?? $0.sentAt) > ($1.completedAt ?? $1.sentAt)
        }
    }

    func move(_ thread: WaitingThread, to state: WorkflowState) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].state = state
        threads[index].isArchived = false
        threads[index].completedAt = state == .done ? .now : nil
        let messageIDs = threads[index].threadMessageIDs
        let mailFlagIndex = state.mailFlagIndex
        persist()

        Task.detached(priority: .utility) {
            let mail = MailAutomationClient()
            for messageID in messageIDs {
                try? mail.setFlag(messageID: messageID, index: mailFlagIndex)
            }
        }
    }

    func restore(_ thread: WaitingThread) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].isArchived = false
        threads[index].state = .done
        threads[index].completedAt = .now
        persist()
    }

    func performDailyHousekeepingIfNeeded(now: Date = .now) {
        let defaults = UserDefaults.standard
        if let lastRun = defaults.object(forKey: housekeepingKey) as? Date,
           now.timeIntervalSince(lastRun) < 24 * 60 * 60 {
            return
        }

        let archiveCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for index in threads.indices where threads[index].state == .done && !threads[index].isArchived {
            if let completedAt = threads[index].completedAt {
                if completedAt <= archiveCutoff {
                    threads[index].isArchived = true
                }
            } else {
                threads[index].completedAt = now
            }
        }
        persist()
        defaults.set(now, forKey: housekeepingKey)
    }

    func scanMail() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let scanStart = ContinuousClock.now
        logger.notice("Mail scan started")

        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try MailAutomationClient().fetchRecentMessages(limit: 5)
            }.value
            processSent(snapshot.sent)
            let messagesToFlag = processInbox(snapshot.inbox)
            lastScanAt = .now
            statusMessage = "Mail connected"
            persist()
            let duration = scanStart.duration(to: .now)
            logger.notice("Mail scan succeeded: sent=\(snapshot.sent.count, privacy: .public) inbox=\(snapshot.inbox.count, privacy: .public) duration=\(String(describing: duration), privacy: .public)")
            Task.detached(priority: .utility) {
                let mail = MailAutomationClient()
                for messageID in messagesToFlag {
                    try? mail.setFlag(messageID: messageID, index: 0)
                }
            }
        } catch {
            statusMessage = error.localizedDescription
            logger.error("Mail scan failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func processSent(_ messages: [MailMessageMetadata]) {
        for message in messages where !message.id.isEmpty && !contains(message.id) {
            let references = message.referencedMessageIDs
            if let index = threads.firstIndex(where: { !$0.threadMessageIDs.isDisjoint(with: references) }) {
                threads[index].threadMessageIDs.insert(message.id)
                threads[index].state = .waiting
                threads[index].completedAt = nil
                threads[index].isArchived = false
            } else {
                threads.append(.init(
                    outboundMessageID: message.id,
                    subject: message.subject,
                    recipient: message.contact,
                    sentAt: message.date,
                    state: .waiting
                ))
            }
        }
    }

    private func processInbox(_ messages: [MailMessageMetadata]) -> [String] {
        var messagesToFlag: [String] = []
        for message in messages where !message.id.isEmpty && !contains(message.id) {
            let references = message.referencedMessageIDs
            guard let index = threads.firstIndex(where: {
                !$0.threadMessageIDs.isDisjoint(with: references)
            }) else { continue }

            threads[index].threadMessageIDs.insert(message.id)
            threads[index].state = .action
            threads[index].completedAt = nil
            threads[index].isArchived = false
            messagesToFlag.append(message.id)
        }
        return messagesToFlag
    }

    private func contains(_ messageID: String) -> Bool {
        threads.contains { $0.threadMessageIDs.contains(messageID) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(threads) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
