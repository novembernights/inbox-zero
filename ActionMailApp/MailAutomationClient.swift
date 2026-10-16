import AppKit
import Foundation

struct MailSnapshot: Sendable {
    let sent: [MailMessageMetadata]
    let inbox: [MailMessageMetadata]
}

struct MailMessageMetadata: Sendable {
    let id: String
    let subject: String
    let contact: String
    let headers: String
    let date: Date

    nonisolated var referencedMessageIDs: Set<String> {
        let relevant = headers
            .split(whereSeparator: \Character.isNewline)
            .filter {
                $0.lowercased().hasPrefix("in-reply-to:") ||
                $0.lowercased().hasPrefix("references:")
            }
            .joined(separator: " ")
        return Set(relevant.matches(of: /<([^>]+)>/).map { String($0.1) })
    }
}

enum MailAutomationError: LocalizedError {
    case script(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .script(let message):
            "Mail access failed: \(message)"
        case .malformedResponse:
            "Mail returned an unreadable response."
        }
    }
}

final class MailAutomationClient: Sendable {
    nonisolated init() {}

    nonisolated func fetchRecentMessages(limit: Int) throws -> MailSnapshot {
        let source = """
        on recentMetadata(aMailbox, itemLimit)
            tell application "Mail" to set messageCount to count of messages of aMailbox
            if messageCount > itemLimit then set messageCount to itemLimit
            if messageCount is 0 then return {}

            tell application "Mail"
                set messageIDs to message id of messages 1 thru messageCount of aMailbox
                set messageSubjects to subject of messages 1 thru messageCount of aMailbox
                set messageSenders to sender of messages 1 thru messageCount of aMailbox
                set messageHeaders to all headers of messages 1 thru messageCount of aMailbox
            end tell

            set collected to {}
            repeat with itemIndex from 1 to messageCount
                set end of collected to {item itemIndex of messageIDs, item itemIndex of messageSubjects, item itemIndex of messageSenders, item itemIndex of messageHeaders}
            end repeat
            return collected
        end recentMetadata

        tell application "Mail"
            set sentItems to my recentMetadata(sent mailbox, \(limit))
            set inboxItems to my recentMetadata(inbox, \(limit))
            return {sentItems, inboxItems}
        end tell
        """

        let result = try execute(source)
        guard result.numberOfItems >= 2,
              let sentDescriptor = result.atIndex(1),
              let inboxDescriptor = result.atIndex(2) else {
            throw MailAutomationError.malformedResponse
        }
        return MailSnapshot(sent: decode(sentDescriptor), inbox: decode(inboxDescriptor))
    }

    nonisolated func setFlag(messageID: String, index: Int) throws {
        let safeID = messageID.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Mail"
            set matchingMessages to every message of inbox whose message id is "\(safeID)"
            repeat with aMessage in matchingMessages
                set flagged status of aMessage to true
                set flag index of aMessage to \(index)
            end repeat
        end tell
        """
        _ = try execute(source)
    }

    nonisolated private func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw MailAutomationError.script("The automation script could not be created.")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Permission was denied."
            throw MailAutomationError.script(message)
        }
        return result
    }

    nonisolated private func decode(_ descriptor: NSAppleEventDescriptor) -> [MailMessageMetadata] {
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { index in
            guard let row = descriptor.atIndex(index), row.numberOfItems >= 4 else { return nil }
            return MailMessageMetadata(
                id: row.atIndex(1)?.stringValue ?? "",
                subject: row.atIndex(2)?.stringValue ?? "(No subject)",
                contact: row.atIndex(3)?.stringValue ?? "Unknown",
                headers: row.atIndex(4)?.stringValue ?? "",
                date: .now
            )
        }
    }
}
