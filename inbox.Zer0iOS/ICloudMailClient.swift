import Foundation
import Security
import SwiftMail

@MainActor
final class ICloudMailClient {
    private let accountsKey = "icloud-mail-account-emails"
    private let passwordKey = "icloud-mail-app-specific-password"
    private let usernameKey = "icloud-mail-imap-username"

    private(set) var accountSyncErrors: [String: String] = [:]

    var storedAccountEmails: [String] {
        UserDefaults.standard.stringArray(forKey: accountsKey) ?? []
    }

    var hasCredentials: Bool {
        storedAccountEmails.contains { credential(for: $0) != nil }
    }

    func connect(email rawEmail: String, appSpecificPassword rawPassword: String) async throws -> String {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let password = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isICloudAddress(email) else { throw ICloudMailError.invalidAddress }
        guard password.filter(\.isLetter).count + password.filter(\.isNumber).count >= 16 else {
            throw ICloudMailError.invalidAppSpecificPassword
        }

        let username = try await validateIMAP(email: email, password: password)
        try ICloudKeychain.write(password, key: accountKey(passwordKey, email: email))
        try ICloudKeychain.write(username, key: accountKey(usernameKey, email: email))

        var accounts = storedAccountEmails.filter { $0.caseInsensitiveCompare(email) != .orderedSame }
        accounts.append(email)
        UserDefaults.standard.set(accounts, forKey: accountsKey)
        accountSyncErrors[email] = nil
        return email
    }

    func disconnect(email: String) {
        ICloudKeychain.delete(accountKey(passwordKey, email: email))
        ICloudKeychain.delete(accountKey(usernameKey, email: email))
        let remaining = storedAccountEmails.filter { $0.caseInsensitiveCompare(email) != .orderedSame }
        UserDefaults.standard.set(remaining, forKey: accountsKey)
        accountSyncErrors[email] = nil
    }

    func disconnectAll() {
        for email in storedAccountEmails { disconnect(email: email) }
        UserDefaults.standard.removeObject(forKey: accountsKey)
    }

    func fetchMessages(since: Date? = nil) async throws -> [InboxMessage] {
        var combined: [InboxMessage] = []
        var successfulAccounts = 0
        var failures: [String: String] = [:]

        for email in storedAccountEmails {
            do {
                combined.append(contentsOf: try await fetchMessages(for: email, since: since))
                successfulAccounts += 1
            } catch {
                if InboxCancellation.matches(error) { throw CancellationError() }
                failures[email] = error.localizedDescription
            }
        }

        accountSyncErrors = failures
        if successfulAccounts == 0, let message = failures.values.first {
            throw ICloudMailError.requestFailed(message)
        }
        return combined.sorted { $0.receivedAt > $1.receivedAt }
    }

    func trash(_ message: InboxMessage) async throws {
        let account = try account(for: message)
        guard let mailbox = message.imapMailbox, let uid = message.imapUID else {
            throw ICloudMailError.missingRemoteMessage
        }
        let server = try await authenticatedServer(for: account)
        do {
            try await server.selectMailbox(mailbox)
            try await server.moveToTrash(messages: UIDSet(UID(uid)))
            try await server.disconnect()
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    func sendNewEmail(
        fromAccount account: String,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String,
        attachments: [OutgoingAttachment]
    ) async throws {
        guard storedAccountEmails.contains(where: { $0.caseInsensitiveCompare(account) == .orderedSame }) else {
            throw ICloudMailError.notConnected
        }
        guard !to.isEmpty, (to + cc + bcc).allSatisfy({ $0.contains("@") }) else {
            throw ICloudMailError.invalidRecipient
        }
        try await send(
            fromAccount: account,
            to: to.map { MailParticipant(name: "", address: $0) },
            cc: cc.map { MailParticipant(name: "", address: $0) },
            bcc: bcc.map { MailParticipant(name: "", address: $0) },
            subject: subject,
            body: body,
            attachments: attachments,
            inReplyTo: nil,
            references: nil
        )
    }

    func sendReply(to message: InboxMessage, body: String, attachments: [OutgoingAttachment]) async throws {
        let recipient = message.replyTo ?? MailParticipant(name: message.senderName, address: message.senderAddress)
        try await send(
            fromAccount: try account(for: message),
            to: [recipient],
            cc: [],
            subject: Self.replySubject(message.subject),
            body: body,
            attachments: attachments,
            inReplyTo: message.rfcMessageID,
            references: message.rfcMessageID
        )
    }

    func sendReplyAll(to message: InboxMessage, body: String, attachments: [OutgoingAttachment]) async throws {
        let account = try account(for: message)
        var seen = Set<String>()
        func unique(_ participants: [MailParticipant]) -> [MailParticipant] {
            participants.compactMap { participant in
                let key = participant.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, key != account.lowercased(), seen.insert(key).inserted else { return nil }
                return participant
            }
        }
        let primary = message.replyTo ?? MailParticipant(name: message.senderName, address: message.senderAddress)
        let to = unique([primary] + (message.toRecipients ?? []))
        let cc = unique(message.ccRecipients ?? [])
        try await send(
            fromAccount: account,
            to: to,
            cc: cc,
            subject: Self.replySubject(message.subject),
            body: body,
            attachments: attachments,
            inReplyTo: message.rfcMessageID,
            references: message.rfcMessageID
        )
    }

    func forward(_ message: InboxMessage, to recipient: String, body: String, attachments: [OutgoingAttachment]) async throws {
        let address = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else { throw ICloudMailError.invalidRecipient }
        let note = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let forwarded = """
        \(note)\(note.isEmpty ? "" : "\n\n")---------- Forwarded message ----------
        From: \(message.senderName) <\(message.senderAddress)>
        Date: \(message.receivedAt.formatted(date: .long, time: .shortened))
        Subject: \(message.subject)

        \(message.plainBodyText.isEmpty ? message.snippet : message.plainBodyText)
        """
        try await send(
            fromAccount: try account(for: message),
            to: [MailParticipant(name: "", address: address)],
            cc: [],
            subject: Self.forwardSubject(message.subject),
            body: forwarded,
            attachments: attachments,
            inReplyTo: nil,
            references: nil
        )
    }

    func downloadAttachment(from message: InboxMessage, attachmentID: String) async throws -> Data {
        let account = try account(for: message)
        guard let mailbox = message.imapMailbox, let uid = message.imapUID else {
            throw ICloudMailError.missingRemoteMessage
        }
        let server = try await authenticatedServer(for: account)
        do {
            try await server.selectMailbox(mailbox)
            let raw = try await server.fetchRawMessage(identifier: UID(uid))
            let parsed = try EMLParser.parse(raw)
            try await server.disconnect()
            guard let data = parsed.parts.first(where: { $0.section.description == attachmentID })?.decodedData() else {
                throw ICloudMailError.attachmentUnavailable
            }
            return data
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    private func fetchMessages(for email: String, since: Date?) async throws -> [InboxMessage] {
        let server = try await authenticatedServer(for: email)
        do {
            _ = try await server.listSpecialUseMailboxes()
            var folders = [try await server.inboxFolder]
            if let archive = try? await server.archiveFolder,
               archive.name.caseInsensitiveCompare(folders[0].name) != .orderedSame {
                folders.append(archive)
            }

            var result: [InboxMessage] = []
            for folder in folders {
                let selection = try await server.selectMailbox(folder.name)
                let limit = since == nil ? (folders.count == 1 ? 75 : 50) : 50
                guard let identifiers = selection.latest(limit) else { continue }
                let infos = try await server.fetchMessageInfosBulk(
                    using: identifiers,
                    options: [.envelope, .internalDate, .flags, .size]
                )
                let eligible = infos.filter { info in
                    guard let since else { return true }
                    return (info.internalDate ?? info.date ?? .distantPast) >= since.addingTimeInterval(-300)
                }
                for info in eligible {
                    try Task.checkCancellation()
                    guard let uid = info.uid else { continue }
                    let raw = try await server.fetchRawMessage(identifier: uid)
                    if let message = try? makeInboxMessage(
                        from: raw,
                        fallback: info,
                        accountEmail: email,
                        mailbox: folder.name,
                        isInbox: folder.attributes.contains(.inbox) || folder.name.caseInsensitiveCompare("INBOX") == .orderedSame,
                        uid: uid.value
                    ) {
                        result.append(message)
                    }
                }
            }
            try await server.disconnect()
            return result
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    private func makeInboxMessage(
        from raw: Data,
        fallback: MessageInfo,
        accountEmail: String,
        mailbox: String,
        isInbox: Bool,
        uid: UInt32
    ) throws -> InboxMessage {
        let parsed = try EMLParser.parse(raw)
        let from = Self.participant(from: parsed.from ?? fallback.from ?? "Unknown sender")
        let html = parsed.htmlBody ?? Self.html(fromPlainText: parsed.textBody ?? "")
        let snippet = parsed.preview(maxLength: 240)
        let rfcID = parsed.header.messageId?.description ?? fallback.messageId?.description
        let stableRemoteID = rfcID ?? "\(mailbox.lowercased())|\(uid)"
        let localID = "icloud|\(accountEmail.lowercased())|\(stableRemoteID)"
        let attachments = parsed.attachments.map { part in
            InboxAttachment(
                id: part.section.description,
                filename: part.suggestedFilename,
                mimeType: part.contentType.components(separatedBy: ";").first ?? part.contentType,
                size: part.size ?? part.decodedData()?.count ?? 0
            )
        }
        return InboxMessage(
            id: localID,
            threadID: rfcID ?? localID,
            senderName: from.displayName,
            senderAddress: from.address,
            subject: parsed.subject ?? fallback.subject ?? "No subject",
            snippet: snippet,
            bodyHTML: html,
            receivedAt: fallback.internalDate ?? parsed.date ?? fallback.date ?? .now,
            queue: .action,
            isVerified: RecognizedBrand.contains(from.address),
            summary: nil,
            suggestedReply: nil,
            participatesInWorkflow: nil,
            attachments: attachments,
            senderLogoURL: nil,
            isInbox: isInbox,
            accountEmail: accountEmail,
            gmailMessageID: nil,
            mailProvider: .iCloud,
            imapMailbox: mailbox,
            imapUID: uid,
            rfcMessageID: rfcID,
            toRecipients: parsed.to.map(Self.participant),
            ccRecipients: parsed.cc.map(Self.participant),
            bccRecipients: parsed.bcc.map(Self.participant),
            replyTo: Self.replyToParticipant(in: parsed.header.additionalFields)
        )
    }

    private func validateIMAP(email: String, password: String) async throws -> String {
        let localPart = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
        var lastError: Error?
        for username in [localPart, email] {
            let server = Self.makeIMAPServer()
            do {
                try await server.connect()
                try await server.login(username: username, password: password)
                _ = try await server.listSpecialUseMailboxes()
                try await server.disconnect()
                return username
            } catch {
                lastError = error
                try? await server.disconnect()
            }
        }
        throw ICloudMailError.authenticationFailed(lastError?.localizedDescription ?? "iCloud rejected the credentials.")
    }

    private func authenticatedServer(for email: String) async throws -> IMAPServer {
        guard let password = credential(for: email) else { throw ICloudMailError.notConnected }
        let username = ICloudKeychain.read(accountKey(usernameKey, email: email))
            ?? email.split(separator: "@", maxSplits: 1).first.map(String.init)
            ?? email
        let server = Self.makeIMAPServer()
        do {
            try await server.connect()
            try await server.login(username: username, password: password)
            return server
        } catch {
            try? await server.disconnect()
            throw ICloudMailError.authenticationFailed(error.localizedDescription)
        }
    }

    private static func makeIMAPServer() -> IMAPServer {
        IMAPServer(
            host: "imap.mail.me.com",
            port: 993,
            transportSecurity: .implicitTLS,
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: .tlsv12,
            responseBufferLimit: 4 * 1024 * 1024
        )
    }

    private func send(
        fromAccount account: String,
        to: [MailParticipant],
        cc: [MailParticipant],
        bcc: [MailParticipant] = [],
        subject: String,
        body: String,
        attachments: [OutgoingAttachment],
        inReplyTo: String?,
        references: String?
    ) async throws {
        guard let password = credential(for: account) else { throw ICloudMailError.notConnected }
        guard !to.isEmpty else { throw ICloudMailError.invalidRecipient }
        var email = Email(
            sender: EmailAddress(name: MailboxPersona.name(for: account), address: account),
            recipients: to.map { EmailAddress(name: $0.name, address: $0.address) },
            ccRecipients: cc.map { EmailAddress(name: $0.name, address: $0.address) },
            bccRecipients: bcc.map { EmailAddress(name: $0.name, address: $0.address) },
            subject: subject,
            textBody: body,
            attachments: attachments.map { Attachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        )
        var headers: [String: String] = [:]
        if let inReplyTo { headers["In-Reply-To"] = inReplyTo }
        if let references { headers["References"] = references }
        email.additionalHeaders = headers.isEmpty ? nil : headers

        let smtp = SMTPServer(
            host: "smtp.mail.me.com",
            port: 587,
            transportSecurity: .startTLS,
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: .tlsv12
        )
        do {
            try await smtp.connect()
            try await smtp.login(username: account, password: password)
            _ = try await smtp.sendEmail(email)
            try await smtp.disconnect()
        } catch {
            try? await smtp.disconnect()
            throw ICloudMailError.sendFailed(error.localizedDescription)
        }

        // SMTP acceptance is the success boundary. Saving a copy to Sent is best-effort
        // so an IMAP failure cannot make the UI encourage a duplicate retry.
        if let imap = try? await authenticatedServer(for: account) {
            if (try? await imap.listSpecialUseMailboxes()) != nil,
               let sent = try? await imap.sentFolder {
                _ = try? await imap.append(email: email, to: sent.name, flags: [.seen], internalDate: .now)
            }
            try? await imap.disconnect()
        }
    }

    private func account(for message: InboxMessage) throws -> String {
        guard let email = message.accountEmail,
              storedAccountEmails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) else {
            throw ICloudMailError.notConnected
        }
        return email
    }

    private func credential(for email: String) -> String? {
        ICloudKeychain.read(accountKey(passwordKey, email: email))
    }

    private func accountKey(_ base: String, email: String) -> String {
        "\(base)-\(email.lowercased())"
    }

    private static func isICloudAddress(_ value: String) -> Bool {
        guard value.contains("@") else { return false }
        let domain = value.split(separator: "@").last.map(String.init)?.lowercased()
        return domain == "icloud.com" || domain == "me.com" || domain == "mac.com"
    }

    private static func participant(from value: String) -> MailParticipant {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let opening = trimmed.lastIndex(of: "<"), let closing = trimmed.lastIndex(of: ">"), opening < closing {
            let name = trimmed[..<opening].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let address = trimmed[trimmed.index(after: opening)..<closing].trimmingCharacters(in: .whitespacesAndNewlines)
            return MailParticipant(name: String(name), address: String(address))
        }
        return MailParticipant(name: "", address: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>\" ")))
    }

    private static func replyToParticipant(in fields: [String: String]?) -> MailParticipant? {
        guard let value = fields?.first(where: { $0.key.caseInsensitiveCompare("reply-to") == .orderedSame })?.value else { return nil }
        return participant(from: value)
    }

    private static func html(fromPlainText text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<html><body><p>\(escaped)</p></body></html>"
    }

    private static func replySubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
    }

    private static func forwardSubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)"
    }
}

private enum ICloudMailError: LocalizedError {
    case invalidAddress
    case invalidAppSpecificPassword
    case authenticationFailed(String)
    case notConnected
    case missingRemoteMessage
    case attachmentUnavailable
    case invalidRecipient
    case requestFailed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an iCloud Mail address ending in @icloud.com, @me.com, or @mac.com."
        case .invalidAppSpecificPassword: "Enter the app-specific password generated for inbox.Zerø, not your Apple Account password."
        case .authenticationFailed(let detail): "iCloud Mail could not connect. Check the address and app-specific password. \(detail)"
        case .notConnected: "Connect this iCloud Mail account again to continue."
        case .missingRemoteMessage: "This iCloud message no longer has enough server information for that action. Sync and try again."
        case .attachmentUnavailable: "The attachment is no longer available from iCloud Mail."
        case .invalidRecipient: "Enter a valid recipient email address."
        case .requestFailed(let detail): "iCloud Mail sync failed: \(detail)"
        case .sendFailed(let detail): "iCloud Mail could not send this message: \(detail)"
        }
    }
}

private enum ICloudKeychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "org.example.inboxzero.ios") + ".icloud-mail"

    static func write(_ value: String, key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ICloudMailError.requestFailed("The Keychain could not save the credential (\(status)).") }
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
