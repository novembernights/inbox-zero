import Foundation
import Observation
import SwiftUI

enum MailboxPersona {
    static func name(for email: String?) -> String {
        guard let email, !email.isEmpty else { return "Mailbox" }
        if let custom = UserDefaults.standard.string(forKey: nameKey(for: email)), !custom.isEmpty {
            return custom
        }
        return email.split(separator: "@").first.map(String.init)?.capitalized ?? "Mailbox"
    }

    static func nameKey(for email: String) -> String {
        "inbox-zero-mailbox-name-\(email.lowercased())"
    }

    static func color(for email: String?) -> Color {
        guard let email else { return .secondary }
        let checksum = email.lowercased().unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return [Color.indigo, .teal, .pink, .purple][checksum % 4]
    }
}

enum InboxQueue: String, Codable, CaseIterable, Identifiable, Sendable {
    case action = "Action"
    case waiting = "Waiting"
    case readLater = "Read Later"
    case done = "Done"

    var id: Self { self }
    var icon: String {
        switch self {
        case .action: "bolt"
        case .waiting: "hourglass"
        case .readLater: "bookmark"
        case .done: "check"
        }
    }

    var color: Color {
        switch self {
        case .action: .red
        case .waiting: .orange
        case .readLater: .blue
        case .done: .green
        }
    }
}

enum MailProvider: String, Codable, Hashable, Sendable {
    case gmail
    case iCloud

    var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .iCloud: "iCloud Mail"
        }
    }
}

struct InboxMessage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var threadID: String
    var senderName: String
    var senderAddress: String
    var subject: String
    var snippet: String
    var bodyHTML: String
    var receivedAt: Date
    var queue: InboxQueue
    var isVerified: Bool
    var summary: String?
    var summaryVersion: Int? = nil
    var summaryIsGenerated: Bool? = nil
    var suggestedReply: String?
    var participatesInWorkflow: Bool?
    var attachments: [InboxAttachment]? = nil
    var senderLogoURL: String? = nil
    var isInbox: Bool? = nil
    var accountEmail: String? = nil
    var gmailMessageID: String? = nil
    var mailProvider: MailProvider? = nil
    var imapMailbox: String? = nil
    var imapUID: UInt32? = nil
    var rfcMessageID: String? = nil
    var toRecipients: [MailParticipant]? = nil
    var ccRecipients: [MailParticipant]? = nil
    var bccRecipients: [MailParticipant]? = nil
    var replyTo: MailParticipant? = nil

    var showsBrandCheck: Bool {
        isVerified || RecognizedBrand.contains(senderAddress)
    }

    var displaySummary: String? {
        guard let summary, !LocalIntelligence.isGeneratedArtifact(summary) else { return nil }
        return summary
    }

    var searchableText: String {
        [senderName, senderAlias, senderAddress, subject, snippet, displaySummary ?? "", plainBodyText]
            .joined(separator: " ")
            .lowercased()
    }

    var senderAlias: String {
        senderName
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { word in
                let value = String(word)
                if value.count > 1, value == value.uppercased() {
                    return value.lowercased()
                }
                return value.first.map { String($0).lowercased() } ?? ""
            }
            .joined()
    }

    var plainBodyText: String {
        bodyHTML
            .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MailParticipant: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var address: String

    var id: String { "\(name.lowercased())|\(address.lowercased())" }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
    }
}

extension String {
    var htmlEntityDecoded: String {
        replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

enum RecognizedBrand {
    static let domains: Set<String> = [
        "apple.com", "booking.com", "emiratesnbd.com", "google.com",
        "linkedin.com", "microsoft.com", "nike.com", "plugin-alliance.com",
        "realtor.com", "revolut.com", "skims.com", "spotify.com",
        "tally.so", "wio.io", "zoho.com"
    ]

    static func contains(_ address: String) -> Bool {
        guard let domain = domain(from: address) else { return false }
        return domains.contains(domain)
    }

    static func domain(from address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let host = address[address.index(after: at)...]
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'"))
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }

        let compoundSuffixes: Set<String> = [
            "co.uk", "org.uk", "com.au", "com.br", "com.cn", "com.sg",
            "com.tr", "co.jp", "co.in", "co.nz", "co.za", "co.ae"
        ]
        let suffix = parts.suffix(2).joined(separator: ".")
        let count = compoundSuffixes.contains(suffix) && parts.count >= 3 ? 3 : 2
        return parts.suffix(count).joined(separator: ".")
    }
}

struct InboxAttachment: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let filename: String
    let mimeType: String
    let size: Int
}

enum SmartAttachmentKind: String, Codable, Hashable, Sendable {
    case calendarInvitation
    case appleWalletPass

    var label: String {
        switch self {
        case .calendarInvitation: "Calendar invitation"
        case .appleWalletPass: "Add to Apple Wallet"
        }
    }

    var iconName: String {
        switch self {
        case .calendarInvitation: "calendar-plus"
        case .appleWalletPass: "wallet-cards"
        }
    }
}

struct RecognizedSmartAttachment: Identifiable, Hashable, Sendable {
    let attachment: InboxAttachment
    let kind: SmartAttachmentKind
    var id: String { attachment.id }
}

extension InboxAttachment {
    var deterministicSmartKind: SmartAttachmentKind? {
        let type = mimeType.lowercased()
        let name = filename.lowercased()
        if type == "text/calendar" || type.contains("calendar") || name.hasSuffix(".ics") {
            return .calendarInvitation
        }
        if type == "application/vnd.apple.pkpass" || type.contains("pkpass") || name.hasSuffix(".pkpass") {
            return .appleWalletPass
        }
        return nil
    }
}

struct SearchAnswer: Identifiable, Sendable {
    let id = UUID()
    let answer: String
    let sources: [InboxMessage]
}

struct OutgoingAttachment: Identifiable, Sendable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data
}

@MainActor
@Observable
final class InboxStore {
    var messages: [InboxMessage] = []
    var isSyncing = false
    var hasCompletedInitialLoad = false
    var accountEmail: String?
    var accountEmails: [String] = []
    var errorMessage: String?
    var lastSyncAt: Date?
    var pendingUndo: (message: InboxMessage, queue: InboxQueue)?

    let intelligence = LocalIntelligence()
    let gmail = GmailClient()
    let iCloud = ICloudMailClient()
    let dailyContext = DailyContextService()
    private let persistence = ProtectedMessageStore()
    private let personalization = MailPersonalizationStore()
    private let searchIndex = MailSearchIndex()
    private let lastSyncKey = "inbox-zero-last-gmail-sync"

    init() {
        lastSyncAt = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    func start() async {
        defer { hasCompletedInitialLoad = true }
        await dailyContext.start()
        intelligence.refreshAvailability()
        do {
            let stored = try persistence.load()
            messages = stored.compactMap { storedMessage in
                guard !storedMessage.id.hasPrefix("preview-") else { return nil }
                var message = storedMessage
                if message.summaryVersion != Self.currentSummaryVersion ||
                    message.summary.map(LocalIntelligence.isGeneratedArtifact) == true {
                    message.summary = nil
                    message.summaryVersion = nil
                    message.summaryIsGenerated = nil
                }
                return message
            }
            searchIndex.replace(with: messages)
        } catch {
            // Protected files can be unavailable briefly while iOS is unlocking the
            // application container. Keep the in-memory state intact and let Gmail
            // recover the library instead of immediately persisting an empty array.
        }
        refreshAccounts()
        guard (gmail.isConfigured && gmail.hasCredentials) || iCloud.hasCredentials else { return }
        await sync()
    }

    func messages(in queue: InboxQueue) -> [InboxMessage] {
        messages.filter { $0.queue == queue && $0.participatesInWorkflow != false }.sorted { $0.receivedAt > $1.receivedAt }
    }

    func count(in queue: InboxQueue) -> Int { messages(in: queue).count }

    func move(_ message: InboxMessage, to queue: InboxQueue) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let oldQueue = messages[index].queue
        messages[index].queue = queue
        messages[index].participatesInWorkflow = true
        personalization.recordQueueChoice(message: message, queue: queue)
        pendingUndo = (message, oldQueue)
        persist()
        if provider(for: message) == .gmail {
            Task { try? await gmail.apply(queue: queue, to: message) }
        }
    }

    func trash(_ message: InboxMessage) async throws {
        switch provider(for: message) {
        case .gmail: try await gmail.trash(message)
        case .iCloud: try await iCloud.trash(message)
        }
        messages.removeAll { $0.id == message.id }
        pendingUndo = nil
        persist()
    }

    func undoLastMove() {
        guard let pendingUndo else { return }
        self.pendingUndo = nil
        guard let index = messages.firstIndex(where: { $0.id == pendingUndo.message.id }) else { return }
        messages[index].queue = pendingUndo.queue
        persist()
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let previousSync = lastSyncAt
            // A missing local cache must trigger a full recovery. Using the previous
            // timestamp here would fetch only newly arrived messages and leave every
            // earlier email invisible after an install, cache read failure, or restore.
            let fetchSince = messages.isEmpty ? nil : previousSync
            var remote: [InboxMessage] = []
            var providerErrors: [Error] = []
            if gmail.isConfigured && gmail.hasCredentials {
                let gmailSince = messages.contains { provider(for: $0) == .gmail } ? fetchSince : nil
                do { remote.append(contentsOf: try await gmail.fetchMessages(since: gmailSince)) }
                catch { providerErrors.append(error) }
            }
            if iCloud.hasCredentials {
                let iCloudSince = messages.contains { provider(for: $0) == .iCloud } ? fetchSince : nil
                do { remote.append(contentsOf: try await iCloud.fetchMessages(since: iCloudSince)) }
                catch { providerErrors.append(error) }
            }
            if remote.isEmpty, let error = providerErrors.first { throw error }
            var uniqueRemote: [String: InboxMessage] = [:]
            for message in remote {
                let existing = uniqueRemote[message.id]
                if existing == nil || (message.isInbox == true && existing?.isInbox != true) {
                    uniqueRemote[message.id] = message
                }
            }
            remote = uniqueRemote.values.sorted { $0.receivedAt > $1.receivedAt }
            // Gmail results can first enter the local library through search or a delayed
            // refresh. Reconsider a full day of recent Inbox mail so those messages do not
            // remain permanently presented as Archive merely because they missed a five-
            // minute sync boundary. Existing workflow choices are preserved by merge().
            let routingCutoff = previousSync?.addingTimeInterval(-86_400)
                ?? Date.now.addingTimeInterval(-86_400)
            let newlyRouted = merge(
                remote,
                autoRouteNewInbox: true,
                recentCutoff: routingCutoff
            )
            for (messageID, queue) in newlyRouted {
                if let message = messages.first(where: { $0.id == messageID }) {
                    if provider(for: message) == .gmail {
                        try? await gmail.apply(queue: queue, to: message)
                    }
                }
            }
            refreshAccounts()
            lastSyncAt = .now
            UserDefaults.standard.set(lastSyncAt, forKey: lastSyncKey)
            persist()
            await refineNewlyRoutedMessages(newlyRouted)
            if let previousSync {
                let notificationCutoff = previousSync.addingTimeInterval(-60)
                let newMail = newlyRouted.keys.compactMap { messageID in
                    messages.first(where: { $0.id == messageID && $0.receivedAt >= notificationCutoff })
                }
                await InboxNotificationCoordinator.deliverNewMail(newMail)
            }
            await enrichPriorityMessages()
        } catch where InboxCancellation.matches(error) || Task.isCancelled {
            // iOS commonly cancels in-flight URLSession work when the app changes
            // lifecycle state. Cancellation is not a Gmail or authentication failure.
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn(clientID: String? = nil, expectedEmail: String? = nil) async {
        do {
            accountEmail = try await gmail.signIn(using: clientID, expectedEmail: expectedEmail)
            refreshAccounts(preferred: accountEmail)
            await sync()
        } catch where InboxCancellation.matches(error) || Task.isCancelled {
            // Closing Google's sign-in sheet is an intentional cancellation, not an error.
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        gmail.signOut()
        refreshAccounts()
    }

    func connectICloud(email: String, appSpecificPassword: String) async throws {
        let connected = try await iCloud.connect(email: email, appSpecificPassword: appSpecificPassword)
        refreshAccounts(preferred: connected)
        await sync()
    }

    func disconnectICloud(email: String) {
        iCloud.disconnect(email: email)
        messages.removeAll {
            provider(for: $0) == .iCloud && $0.accountEmail?.caseInsensitiveCompare(email) == .orderedSame
        }
        refreshAccounts()
        persist()
    }

    func search(_ query: String) async -> SearchAnswer? {
        if isRecentMessageRequest(query) {
            return await recentMessagesAnswer(for: query)
        }

        let naturalQuery = MailSearchRanking.interpret(query)

        // An explicit sender request is one place where Gmail is the source of
        // truth. Previously the local fuzzy index returned first, so a query
        // such as “email from Riley” could be satisfied by a merely similar
        // cached sender and Gmail was never consulted. Search Google first for
        // these requests; keep the deterministic index as the offline fallback.
        if let googleAnswer = await googleSenderLookupAnswer(for: query, parsed: naturalQuery) {
            intelligence.prepareForSearch()
            return googleAnswer
        }

        // Most Ask requests are retrieval commands ("show email from Riley",
        // "invoices this month", "messages with attachments"). They already
        // contain enough explicit structure for the deterministic parser and
        // local FTS index, so do not put an on-device model pass or a Gmail
        // round-trip on their critical path. The model remains available for
        // questions that actually need synthesis.
        if let fastAnswer = deterministicLookupAnswer(for: query, parsed: naturalQuery) {
            intelligence.prepareForSearch()
            return fastAnswer
        }

        let plan = await intelligence.searchPlan(for: query)
        // Deterministic parsing wins for explicit user constraints. The model can
        // enrich an ambiguous question, but it must never replace “from Riley”
        // with another sender or turn a filter such as “has attachments” into a
        // literal body-text keyword.
        let sender = naturalQuery.senderCandidate ?? plan.sender
        let terms = naturalQuery.contentTerms.isEmpty &&
            sender == nil &&
            !naturalQuery.requiresAttachment
            ? uniqueSearchTerms(plan.keywords)
            : naturalQuery.contentTerms
        // The model may enrich ranking terms, but only the user's explicit words
        // may add exclusionary filters. Otherwise a harmless query such as
        // “show me email from Riley” can incorrectly become attachment-only or
        // last-30-days-only and hide the requested sender.
        let requiresAttachment = naturalQuery.requiresAttachment
        let requiresCalendarInvitation = naturalQuery.requiresCalendarInvitation
        let effectivePlan = IntelligenceSearchPlan(
            intent: plan.intent,
            sender: sender,
            keywords: terms,
            timeScope: intelligenceTimeScope(for: naturalQuery.timeScope),
            requiresAttachment: requiresAttachment
        )
        guard !terms.isEmpty || sender != nil || requiresAttachment || requiresCalendarInvitation else { return nil }

        var sources = rankedSources(
            terms: terms,
            sender: sender,
            requiresAttachment: requiresAttachment,
            requiresCalendarInvitation: requiresCalendarInvitation,
            plan: effectivePlan,
            limit: naturalQuery.wantsAllMatches ? 100 : 8
        )
        let hasStrongLocalMatch = !sources.isEmpty
        let explicitMessageLookup = effectivePlan.intent == .findMessages || naturalQuery.isMessageLookup || isMessageLookup(query)

        // Speech substitutions such as “Rilie” for “Riley” need a local sender
        // vocabulary. If the current cache cannot resolve the spoken name, fetch
        // a broader candidate set first, merge it, and then resolve fuzzily before
        // issuing the precise Gmail query.
        if explicitMessageLookup,
           let sender,
           knownResolvedSender(sender) == nil,
           gmail.isConfigured,
           gmail.hasCredentials,
           let discovery = try? await gmail.searchMessages(
                query: gmailSearchQuery(
                    terms: terms,
                    sender: nil,
                    requiresAttachment: requiresAttachment,
                    requiresCalendarInvitation: requiresCalendarInvitation,
                    plan: effectivePlan
                ),
                limit: 500
           ) {
            _ = merge(discovery)
            persist()
            sources = rankedSources(
                terms: terms,
                sender: sender,
                requiresAttachment: requiresAttachment,
                requiresCalendarInvitation: requiresCalendarInvitation,
                plan: effectivePlan,
                limit: naturalQuery.wantsAllMatches ? 100 : 8
            )
        }
        if (!hasStrongLocalMatch || explicitMessageLookup), gmail.isConfigured, gmail.hasCredentials,
           let remote = try? await gmail.searchMessages(query: gmailSearchQuery(
                terms: terms,
                sender: resolvedSender(sender),
                requiresAttachment: requiresAttachment,
                requiresCalendarInvitation: requiresCalendarInvitation,
                plan: effectivePlan
           )) {
            _ = merge(remote)
            persist()
            sources = rankedSources(
                terms: terms,
                sender: sender,
                requiresAttachment: requiresAttachment,
                requiresCalendarInvitation: requiresCalendarInvitation,
                plan: effectivePlan,
                limit: naturalQuery.wantsAllMatches ? 100 : 8
            )
        }
        guard !sources.isEmpty else { return nil }
        if explicitMessageLookup {
            intelligence.prepareForSearch()
            return SearchAnswer(answer: lookupAnswer(for: sources), sources: sources)
        }
        let answer = await intelligence.answer(question: query, sources: sources)
        intelligence.prepareForSearch()
        return SearchAnswer(answer: answer, sources: sources)
    }

    func prepareSearchIntelligence() {
        intelligence.prepareForSearch()
    }

    private func isRecentMessageRequest(_ query: String) -> Bool {
        let value = query.lowercased()
        let asksForMail = value.contains("email") || value.contains("mail") || value.contains("message")
        let asksForRecency = value.contains("most recent") || value.contains("latest") ||
            value.contains("newest") || value.contains("new emails") || value.contains("recent emails") ||
            value.contains("recent mail") || value.contains("recent messages")
        return asksForMail && asksForRecency
    }

    private func deterministicLookupAnswer(
        for query: String,
        parsed: NaturalLanguageMailQuery
    ) -> SearchAnswer? {
        let isLookup = parsed.isMessageLookup || isMessageLookup(query)
        guard isLookup else { return nil }

        let plan = IntelligenceSearchPlan(
            intent: .findMessages,
            sender: parsed.senderCandidate,
            keywords: parsed.contentTerms,
            timeScope: intelligenceTimeScope(for: parsed.timeScope),
            requiresAttachment: parsed.requiresAttachment
        )
        let sources = rankedSources(
            terms: parsed.contentTerms,
            sender: parsed.senderCandidate,
            requiresAttachment: parsed.requiresAttachment,
            requiresCalendarInvitation: parsed.requiresCalendarInvitation,
            plan: plan,
            limit: parsed.wantsAllMatches ? 100 : 8
        )
        guard !sources.isEmpty else { return nil }
        return SearchAnswer(answer: lookupAnswer(for: sources), sources: sources)
    }

    private func googleSenderLookupAnswer(
        for query: String,
        parsed: NaturalLanguageMailQuery
    ) async -> SearchAnswer? {
        guard (parsed.isMessageLookup || isMessageLookup(query)),
              let sender = parsed.senderCandidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sender.isEmpty,
              gmail.isConfigured,
              gmail.hasCredentials else { return nil }

        let plan = IntelligenceSearchPlan(
            intent: .findMessages,
            sender: sender,
            keywords: parsed.contentTerms,
            timeScope: intelligenceTimeScope(for: parsed.timeScope),
            requiresAttachment: parsed.requiresAttachment
        )
        let gmailQuery = gmailSearchQuery(
            terms: parsed.contentTerms,
            sender: sender,
            requiresAttachment: parsed.requiresAttachment,
            requiresCalendarInvitation: parsed.requiresCalendarInvitation,
            plan: plan
        )
        guard let remote = try? await gmail.searchMessages(
            query: gmailQuery,
            limit: parsed.wantsAllMatches ? 100 : 25
        ), !remote.isEmpty else { return nil }

        _ = merge(remote)
        persist()
        // Gmail has already applied the authoritative from: constraint. Keep
        // its newest-first order and do not mix fuzzy local matches back in.
        let sources = Array(remote.prefix(parsed.wantsAllMatches ? 100 : 8))
        return SearchAnswer(answer: lookupAnswer(for: sources), sources: sources)
    }

    private func recentMessagesAnswer(for query: String) async -> SearchAnswer? {
        var sources = Array(messages
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(8))

        // The synchronized local mailbox is the primary search store. Only hit
        // Gmail here when the local store is empty (for example, immediately
        // after first sign-in); otherwise a simple "recent emails" query was
        // needlessly downloading and decoding up to 100 messages.
        if sources.isEmpty,
           gmail.isConfigured,
           gmail.hasCredentials,
           let remote = try? await gmail.searchMessages(query: "newer_than:30d", limit: 25) {
            _ = merge(remote)
            persist()
            sources = Array(messages.sorted { $0.receivedAt > $1.receivedAt }.prefix(8))
        }
        guard let newest = sources.first else { return nil }

        let asksForSummary = query.localizedCaseInsensitiveContains("summarize") ||
            query.localizedCaseInsensitiveContains("summary") ||
            query.localizedCaseInsensitiveContains("what did")
        if asksForSummary {
            let answer = await intelligence.answer(question: query, sources: sources)
            return SearchAnswer(answer: answer, sources: sources)
        }

        let mailbox = mailboxDescription(for: newest.accountEmail)
        let received = newest.receivedAt.formatted(date: .abbreviated, time: .shortened)
        let answer = "Here are your \(sources.count) most recent emails, newest first. The latest is “\(newest.subject)” from \(newest.senderName), received \(received) in \(mailbox)."
        return SearchAnswer(answer: answer, sources: sources)
    }

    private func mailboxDescription(for email: String?) -> String {
        let persona = MailboxPersona.name(for: email)
        if Int(persona) != nil { return "mailbox \(persona)" }
        if persona == "Mailbox" { return "your mailbox" }
        return "your \(persona) mailbox"
    }

    private func isMessageLookup(_ query: String) -> Bool {
        let value = query.lowercased()
        return value.contains("find") || value.contains("show") || value.contains("any email") ||
            value.contains("emails from") || value.contains("email from") || value.contains("messages from")
    }

    /// Foundation Models usually extracts a sender, but a direct command such as
    /// “show me messages from Riley” must remain reliable when the model is busy,
    /// unavailable, or returns an incomplete plan.
    private func explicitSenderName(in query: String) -> String? {
        let lowercased = query.lowercased()
        guard let marker = lowercased.range(of: " from ") else { return nil }
        var candidate = String(query[marker.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !candidate.isEmpty else { return nil }

        let stoppingPhrases = [" about ", " with ", " since ", " before ", " after ", " during ", " this month", " last week"]
        let candidateLowercased = candidate.lowercased()
        let stop = stoppingPhrases.compactMap { candidateLowercased.range(of: $0)?.lowerBound }.min()
        if let stop { candidate = String(candidate[..<stop]) }
        let words = candidate.split(whereSeparator: { $0.isWhitespace }).prefix(4)
        let result = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return result.isEmpty ? nil : result
    }

    private func lookupAnswer(for sources: [InboxMessage]) -> String {
        guard let first = sources.first else { return "I couldn't find a matching email." }
        let count = sources.count
        let mailbox = MailboxPersona.name(for: first.accountEmail)
        if count == 1 {
            return "I found one matching email: “\(first.subject)” from \(first.senderName), received \(first.receivedAt.formatted(date: .abbreviated, time: .omitted)) in \(mailbox)."
        }
        return "I found \(count) matching emails. The most relevant is “\(first.subject)” from \(first.senderName), received \(first.receivedAt.formatted(date: .abbreviated, time: .omitted)) in \(mailbox)."
    }

    private func rankedSources(
        terms: [String],
        sender: String?,
        requiresAttachment: Bool,
        requiresCalendarInvitation: Bool,
        plan: IntelligenceSearchPlan,
        limit: Int
    ) -> [InboxMessage] {
        let indexedIDs = searchIndex.matchingIDs(for: terms)
        let eligibleMessages = messages.filter { message in
            (indexedIDs == nil || indexedIDs?.contains(message.id) == true) &&
            matchesTimeScope(message.receivedAt, scope: plan.timeScope) &&
            (!requiresAttachment || !(message.attachments ?? []).isEmpty) &&
            (!requiresCalendarInvitation || message.attachments?.contains(where: { $0.deterministicSmartKind == .calendarInvitation }) == true)
        }
        let documents = eligibleMessages.map {
            MailSearchDocument(
                id: $0.id,
                senderName: $0.senderName,
                senderAlias: $0.senderAlias,
                senderAddress: $0.senderAddress,
                subject: $0.subject,
                searchableText: $0.searchableText,
                receivedAt: $0.receivedAt,
                hasAttachment: !($0.attachments ?? []).isEmpty,
                hasCalendarInvitation: $0.attachments?.contains(where: { $0.deterministicSmartKind == .calendarInvitation }) == true
            )
        }
        let boosts = personalization.searchBoosts(for: documents, terms: terms)
        let ids = MailSearchRanking.rankedIDs(
            documents: documents,
            terms: terms,
            senderCandidate: sender,
            requiresAttachment: requiresAttachment,
            requiresCalendarInvitation: requiresCalendarInvitation,
            learnedBoosts: boosts,
            limit: limit
        )
        let messagesByID = Dictionary(uniqueKeysWithValues: eligibleMessages.map { ($0.id, $0) })
        return ids.compactMap { messagesByID[$0] }
    }

    private func gmailSearchQuery(
        terms: [String],
        sender: String?,
        requiresAttachment: Bool,
        requiresCalendarInvitation: Bool,
        plan: IntelligenceSearchPlan
    ) -> String {
        let senderTerms = sender.map { MailSearchRanking.terms(in: $0) } ?? []
        let remainingTerms = terms.filter { !senderTerms.contains($0) }
        var components: [String] = []
        // Repeating from: makes multi-word names an AND match against the From
        // header and avoids the ambiguous grouped syntax that produced broad
        // results for short names such as Riley.
        components.append(contentsOf: senderTerms.map { "from:\($0)" })
        if !remainingTerms.isEmpty {
            components.append(MailSearchRanking.gmailQuery(for: remainingTerms))
        }
        if requiresAttachment { components.append("has:attachment") }
        if requiresCalendarInvitation { components.append("filename:ics") }
        switch plan.timeScope {
        case .anyTime:
            break
        case .today:
            components.append("newer_than:1d")
        case .lastSevenDays:
            components.append("newer_than:7d")
        case .lastThirtyDays:
            components.append("newer_than:30d")
        case .thisMonth:
            let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
            components.append("after:\(Self.gmailDateFormatter.string(from: start))")
        case .thisYear:
            let start = Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: .now), month: 1, day: 1)) ?? .now
            components.append("after:\(Self.gmailDateFormatter.string(from: start))")
        }
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func resolvedSender(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let documents = messages.map {
            MailSearchDocument(
                id: $0.id,
                senderName: $0.senderName,
                senderAlias: $0.senderAlias,
                senderAddress: $0.senderAddress,
                subject: $0.subject,
                searchableText: $0.searchableText,
                receivedAt: $0.receivedAt
            )
        }
        return MailSearchRanking.bestSenderMatch(for: candidate, in: documents)
    }

    private func knownResolvedSender(_ candidate: String) -> String? {
        let documents = messages.map {
            MailSearchDocument(
                id: $0.id,
                senderName: $0.senderName,
                senderAlias: $0.senderAlias,
                senderAddress: $0.senderAddress,
                subject: $0.subject,
                searchableText: $0.searchableText,
                receivedAt: $0.receivedAt
            )
        }
        return MailSearchRanking.knownSenderMatch(for: candidate, in: documents)
    }

    private func intelligenceTimeScope(for scope: MailSearchTimeScope?) -> IntelligenceSearchPlan.TimeScope {
        switch scope {
        case .today: .today
        case .lastSevenDays: .lastSevenDays
        case .lastThirtyDays: .lastThirtyDays
        case .thisMonth: .thisMonth
        case .thisYear: .thisYear
        case nil: .anyTime
        }
    }

    private func matchesTimeScope(_ date: Date, scope: IntelligenceSearchPlan.TimeScope) -> Bool {
        let calendar = Calendar.current
        switch scope {
        case .anyTime:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .lastSevenDays:
            return date >= .now.addingTimeInterval(-7 * 86_400)
        case .lastThirtyDays:
            return date >= .now.addingTimeInterval(-30 * 86_400)
        case .thisMonth:
            return calendar.isDate(date, equalTo: .now, toGranularity: .month)
        case .thisYear:
            return calendar.isDate(date, equalTo: .now, toGranularity: .year)
        }
    }

    private func uniqueSearchTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    private static let gmailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    func recordSearchSelection(query: String, message: InboxMessage) {
        personalization.recordSearchSelection(queryTerms: MailSearchRanking.terms(in: query), message: message)
    }

    func draftReply(to message: InboxMessage, instruction: String) async -> String {
        await intelligence.draftReply(to: message, instruction: instruction)
    }

    func summary(for message: InboxMessage) async -> String {
        let storedMessage = messages.first(where: { $0.id == message.id })
        if let summary = storedMessage?.displaySummary ?? message.displaySummary,
           (storedMessage?.summaryVersion ?? message.summaryVersion) == Self.currentSummaryVersion {
            return summary
        }
        let result = await intelligence.summarize(message)
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].summary = result.text
            messages[index].summaryVersion = Self.currentSummaryVersion
            messages[index].summaryIsGenerated = result.isGenerated
            persist()
        }
        return result.text
    }

    func summaryIsAI(for message: InboxMessage) -> Bool {
        messages.first(where: { $0.id == message.id })?.summaryIsGenerated
            ?? message.summaryIsGenerated
            ?? false
    }

    func sendReply(to message: InboxMessage, body: String, attachments: [OutgoingAttachment]) async throws {
        switch provider(for: message) {
        case .gmail: try await gmail.sendReply(to: message, body: body, attachments: attachments)
        case .iCloud: try await iCloud.sendReply(to: message, body: body, attachments: attachments)
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
        switch provider(forAccount: account) {
        case .gmail:
            try await gmail.sendNewEmail(
                fromAccount: account,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: body,
                attachments: attachments
            )
        case .iCloud:
            try await iCloud.sendNewEmail(
                fromAccount: account,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: body,
                attachments: attachments
            )
        }
    }

    func sendReplyAll(to message: InboxMessage, body: String, attachments: [OutgoingAttachment]) async throws {
        switch provider(for: message) {
        case .gmail: try await gmail.sendReplyAll(to: message, body: body, attachments: attachments)
        case .iCloud: try await iCloud.sendReplyAll(to: message, body: body, attachments: attachments)
        }
    }

    func forward(_ message: InboxMessage, to recipient: String, body: String, attachments: [OutgoingAttachment]) async throws {
        switch provider(for: message) {
        case .gmail: try await gmail.forward(message, to: recipient, body: body, attachments: attachments)
        case .iCloud: try await iCloud.forward(message, to: recipient, body: body, attachments: attachments)
        }
    }

    func download(_ attachment: InboxAttachment, from message: InboxMessage) async throws -> Data {
        switch provider(for: message) {
        case .gmail: try await gmail.downloadAttachment(from: message, attachmentID: attachment.id)
        case .iCloud: try await iCloud.downloadAttachment(from: message, attachmentID: attachment.id)
        }
    }

    func provider(for message: InboxMessage) -> MailProvider {
        if let provider = message.mailProvider { return provider }
        if let email = message.accountEmail,
           iCloud.storedAccountEmails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
            return .iCloud
        }
        return .gmail
    }

    func provider(forAccount email: String) -> MailProvider {
        iCloud.storedAccountEmails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) ? .iCloud : .gmail
    }

    private func refreshAccounts(preferred: String? = nil) {
        accountEmails = gmail.storedAccountEmails + iCloud.storedAccountEmails.filter { iCloudEmail in
            !gmail.storedAccountEmails.contains(where: { $0.caseInsensitiveCompare(iCloudEmail) == .orderedSame })
        }
        if let preferred,
           accountEmails.contains(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) {
            accountEmail = preferred
        } else {
            accountEmail = accountEmails.first
        }
    }

    @discardableResult
    private func merge(
        _ remote: [InboxMessage],
        autoRouteNewInbox: Bool = false,
        recentCutoff: Date? = nil
    ) -> [String: InboxQueue] {
        let realMessages = messages.filter { !$0.id.hasPrefix("preview-") }
        let existing = Dictionary(uniqueKeysWithValues: realMessages.map { ($0.id, $0) })
        var newlyRouted: [String: InboxQueue] = [:]
        let refreshed = remote.map { incoming -> InboxMessage in
            let isRecentEnough = recentCutoff.map { incoming.receivedAt >= $0 } ?? true
            let shouldEnterWorkflow = autoRouteNewInbox
                && incoming.isInbox == true
                && isRecentEnough
            guard let saved = existing[incoming.id] else {
                var discovered = incoming
                if shouldEnterWorkflow {
                    discovered.queue = initialQueue(for: incoming)
                    discovered.participatesInWorkflow = true
                    newlyRouted[incoming.id] = discovered.queue
                }
                return discovered
            }
            var merged = incoming
            merged.queue = saved.queue
            merged.summary = saved.displaySummary
            merged.summaryVersion = saved.displaySummary == nil ? nil : saved.summaryVersion
            merged.summaryIsGenerated = saved.displaySummary == nil ? nil : saved.summaryIsGenerated
            merged.suggestedReply = saved.suggestedReply
            if saved.participatesInWorkflow == true { merged.participatesInWorkflow = true }
            if shouldEnterWorkflow,
               saved.participatesInWorkflow != true {
                merged.queue = initialQueue(for: incoming)
                merged.participatesInWorkflow = true
                newlyRouted[incoming.id] = merged.queue
            }
            return merged
        }
        let remoteIDs = Set(remote.map(\.id))
        messages = refreshed + realMessages.filter { !remoteIDs.contains($0.id) }
        return newlyRouted
    }

    private func refineNewlyRoutedMessages(_ routed: [String: InboxQueue]) async {
        for (messageID, provisionalQueue) in routed {
            guard let message = messages.first(where: { $0.id == messageID }) else { continue }
            let refinedQueue = await intelligence.classify(message, fallback: provisionalQueue)
            guard refinedQueue != provisionalQueue,
                  let index = messages.firstIndex(where: { $0.id == messageID }),
                  messages[index].queue == provisionalQueue else { continue }
            messages[index].queue = refinedQueue
            if provider(for: messages[index]) == .gmail {
                try? await gmail.apply(queue: refinedQueue, to: messages[index])
            }
        }
        persist()
    }

    private func initialQueue(for message: InboxMessage) -> InboxQueue {
        if let learnedQueue = personalization.preferredQueue(for: message) { return learnedQueue }
        let text = "\(message.senderName) \(message.senderAddress) \(message.subject) \(message.snippet)".lowercased()

        let actionSignals = [
            "action required", "requires your", "payment due", "amount due", "overdue", "past due",
            "please pay", "please reply", "please respond", "please review", "please approve",
            "please sign", "please submit", "please confirm", "verify your", "verification required",
            "rsvp", "deadline", "expires", "failed", "declined", "problem with", "attention needed"
        ]
        if actionSignals.contains(where: text.contains) { return .action }

        let waitingSignals = [
            "we received your", "we have received", "under review", "being reviewed", "in review",
            "we are reviewing", "we're reviewing", "we will get back", "we'll get back",
            "we will contact you", "we'll contact you", "currently processing", "being processed",
            "in progress", "pending approval", "pending review", "awaiting processing"
        ]
        if waitingSignals.contains(where: text.contains) { return .waiting }

        let doneSignals = [
            "payment received", "payment successful", "payment complete", "order confirmed",
            "order delivered", "transfer complete", "transfer sent", "successfully completed",
            "has been completed", "resolved", "receipt for", "booking confirmed"
        ]
        if doneSignals.contains(where: text.contains) { return .done }

        let readLaterSignals = [
            "newsletter", "digest", "weekly update", "monthly update", "job alert", "new collection",
            "new season", "sale", "special offer", "promotion", "insights", "roundup", "what's new",
            "unsubscribe", "marketing"
        ]
        if readLaterSignals.contains(where: text.contains) { return .readLater }

        return .action
    }

    private func enrichPriorityMessages() async {
        for message in messages(in: .action).prefix(3)
        where message.summaryVersion != Self.currentSummaryVersion {
            let result = await intelligence.summarize(message)
            guard let index = messages.firstIndex(where: { $0.id == message.id }) else { continue }
            messages[index].summary = result.text
            messages[index].summaryVersion = Self.currentSummaryVersion
            messages[index].summaryIsGenerated = result.isGenerated
        }
        persist()
    }

    private func persist() {
        try? persistence.save(messages)
        searchIndex.replace(with: messages)
    }

    private static let currentSummaryVersion = 9

    // Entirely fictional fixtures. Reserved example domains never identify a mailbox owner.
    static let previewMessages: [InboxMessage] = [
        .init(id: "preview-welcome", threadID: "thread-welcome", senderName: "Example Team", senderAddress: "hello@example.com", subject: "Welcome to your preview inbox", snippet: "Explore your email workflow with fictional messages.", bodyHTML: "<h1>Welcome</h1><p>This is a fictional preview message. No account is connected.</p>", receivedAt: .now, queue: .action, isVerified: false, summary: "Explore the preview inbox without connecting an account.", suggestedReply: nil, participatesInWorkflow: true),
        .init(id: "preview-review", threadID: "thread-review", senderName: "Alex Example", senderAddress: "alex@example.com", subject: "Project review", snippet: "Would tomorrow afternoon work for a review?", bodyHTML: "<p>Would tomorrow afternoon work for a project review?</p>", receivedAt: .now.addingTimeInterval(-1800), queue: .action, isVerified: false, summary: "Alex proposes a project review tomorrow afternoon.", suggestedReply: "Tomorrow afternoon works. Speak soon,", participatesInWorkflow: true, attachments: [.init(id: "preview-calendar", filename: "Project review.ics", mimeType: "text/calendar", size: 2048)]),
        .init(id: "preview-reading", threadID: "thread-reading", senderName: "Example Journal", senderAddress: "journal@example.org", subject: "Your reading list", snippet: "Three ideas to explore this week.", bodyHTML: "<h2>Reading list</h2><p>A fictional digest for testing the Read Later queue.</p>", receivedAt: .now.addingTimeInterval(-7200), queue: .readLater, isVerified: false, summary: "A fictional weekly reading list.", suggestedReply: nil, participatesInWorkflow: true),
        .init(id: "preview-team", threadID: "thread-team", senderName: "Example Project", senderAddress: "team@example.org", subject: "Waiting for feedback", snippet: "We will send feedback tomorrow.", bodyHTML: "<p>We will send feedback tomorrow.</p>", receivedAt: .now.addingTimeInterval(-14400), queue: .waiting, isVerified: false, summary: nil, suggestedReply: nil, participatesInWorkflow: true),
        .init(id: "preview-complete", threadID: "thread-complete", senderName: "Example Support", senderAddress: "support@example.net", subject: "Request completed", snippet: "Your example request is complete.", bodyHTML: "<p>This fictional request has been completed.</p>", receivedAt: .now.addingTimeInterval(-86400), queue: .done, isVerified: false, summary: nil, suggestedReply: nil, participatesInWorkflow: true),
        .init(id: "preview-archive", threadID: "thread-archive", senderName: "Example Archive", senderAddress: "archive@example.net", subject: "Archived notes", snippet: "A fictional archived message.", bodyHTML: "<p>This fictional archived message is available through All Mail.</p>", receivedAt: .now.addingTimeInterval(-120 * 86400), queue: .action, isVerified: false, summary: nil, suggestedReply: nil, participatesInWorkflow: false)
    ]
}
