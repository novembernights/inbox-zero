import Foundation

struct MailSearchDocument: Sendable {
    let id: String
    let senderName: String
    let senderAlias: String
    let senderAddress: String
    let subject: String
    let searchableText: String
    let receivedAt: Date
    let hasAttachment: Bool
    let hasCalendarInvitation: Bool

    init(
        id: String,
        senderName: String,
        senderAlias: String,
        senderAddress: String,
        subject: String,
        searchableText: String,
        receivedAt: Date,
        hasAttachment: Bool = false,
        hasCalendarInvitation: Bool = false
    ) {
        self.id = id
        self.senderName = senderName
        self.senderAlias = senderAlias
        self.senderAddress = senderAddress
        self.subject = subject
        self.searchableText = searchableText
        self.receivedAt = receivedAt
        self.hasAttachment = hasAttachment
        self.hasCalendarInvitation = hasCalendarInvitation
    }
}

struct NaturalLanguageMailQuery: Equatable, Sendable {
    let senderCandidate: String?
    let contentTerms: [String]
    let requiresAttachment: Bool
    let requiresCalendarInvitation: Bool
    let isMessageLookup: Bool
    let wantsAllMatches: Bool
    let timeScope: MailSearchTimeScope?
}

enum MailSearchTimeScope: Equatable, Sendable {
    case today
    case lastSevenDays
    case lastThirtyDays
    case thisMonth
    case thisYear
}

enum MailSearchRanking {
    private static let stopWords: Set<String> = [
        "a", "about", "all", "an", "and", "any", "are", "at", "can", "contain", "containing",
        "contains", "could", "did", "do", "does", "every",
        "email", "emails", "for", "find", "from", "give", "how", "i", "in", "is", "it",
        "has", "have", "include", "includes", "including", "looking", "mail", "message", "messages",
        "latest", "me", "most", "my", "newest", "next", "of", "on", "please", "recent", "search",
        "show", "tell", "that", "the", "this", "to", "was", "were", "what", "when", "where",
        "which", "who", "why", "with", "would"
    ]

    private static let attachmentWords: Set<String> = [
        "attachment", "attachments", "attached", "file", "files"
    ]

    private static let calendarWords: Set<String> = [
        "calendar", "invite", "invites", "invitation", "invitations", "meeting"
    ]

    private static let timeWords: Set<String> = [
        "today", "day", "days", "week", "month", "year", "last", "past", "this"
    ]

    static func interpret(_ query: String) -> NaturalLanguageMailQuery {
        let normalized = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let lower = normalized.lowercased()
        let sender = explicitSenderCandidate(in: normalized)
        let requestsCalendar = [
            "calendar invite", "calendar invitation", "meeting invite", "meeting invitation",
            "event invite", "event invitation", ".ics"
        ].contains(where: lower.contains)
        let requestsAttachment = requestsCalendar || [
            "with attachment", "with attachments", "has attachment", "have attachment",
            "attached file", "attached files", "with file", "with files", "has file", "have files",
            "attachment", "attachments"
        ].contains(where: lower.contains)

        let senderTerms = sender.map(terms(in:)) ?? []
        let excluded = stopWords
            .union(attachmentWords)
            .union(requestsCalendar ? calendarWords : [])
            .union(timeWords)
            .union(senderTerms)
        let content = terms(in: normalized).filter { !excluded.contains($0) }
        let lookup = lower.contains("find") || lower.contains("show") ||
            lower.contains("which email") || lower.contains("which message") ||
            lower.contains("email from") || lower.contains("emails from") ||
            lower.contains("message from") || lower.contains("messages from") ||
            lower.contains("recent email") || lower.contains("recent message") ||
            lower.contains("latest email") || lower.contains("latest message") ||
            requestsAttachment

        let rawWords = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return NaturalLanguageMailQuery(
            senderCandidate: sender,
            contentTerms: content,
            requiresAttachment: requestsAttachment,
            requiresCalendarInvitation: requestsCalendar,
            isMessageLookup: lookup,
            wantsAllMatches: rawWords.contains("all") || rawWords.contains("every"),
            timeScope: explicitTimeScope(in: lower)
        )
    }

    private static func explicitTimeScope(in query: String) -> MailSearchTimeScope? {
        if query.contains("today") { return .today }
        if query.contains("last 7 days") || query.contains("past 7 days") || query.contains("last week") {
            return .lastSevenDays
        }
        if query.contains("last 30 days") || query.contains("past 30 days") || query.contains("last month") {
            return .lastThirtyDays
        }
        if query.contains("this month") { return .thisMonth }
        if query.contains("this year") { return .thisYear }
        return nil
    }

    static func terms(in query: String) -> [String] {
        var seen = Set<String>()
        return query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { term in
                guard term.count > 1,
                      !term.allSatisfy(\.isNumber),
                      !stopWords.contains(term),
                      seen.insert(term).inserted else { return false }
                return true
            }
    }

    /// Gmail separates terms with spaces for AND matching. Curly braces would
    /// turn this into OR matching and repeatedly return unrelated messages.
    static func gmailQuery(for terms: [String]) -> String {
        terms.joined(separator: " ")
    }

    static func rankedIDs(
        documents: [MailSearchDocument],
        terms: [String],
        senderCandidate: String? = nil,
        requiresAttachment: Bool = false,
        requiresCalendarInvitation: Bool = false,
        learnedBoosts: [String: Int] = [:],
        limit: Int = 6
    ) -> [String] {
        let eligible = documents.filter { document in
            (!requiresAttachment || document.hasAttachment) &&
            (!requiresCalendarInvitation || document.hasCalendarInvitation)
        }
        let knownSender = senderCandidate.flatMap { knownSenderMatch(for: $0, in: eligible) }
        let resolvedSender = knownSender ?? senderCandidate
        let senderTerms = resolvedSender.map(terms(in:)) ?? []
        let allTerms = unique(senderTerms + terms)
        if allTerms.isEmpty {
            return eligible.sorted { $0.receivedAt > $1.receivedAt }.prefix(limit).map(\.id)
        }
        let requiredContentMatches = minimumRequiredMatches(for: terms.count)
        let phrase = terms.joined(separator: " ")

        let ranked = eligible.compactMap { document -> (MailSearchDocument, Int, Int)? in
            let sender = document.senderName.lowercased()
            let alias = document.senderAlias.lowercased()
            let address = document.senderAddress.lowercased()
            let subject = document.subject.lowercased()
            let searchable = document.searchableText.lowercased()
            var score = 0
            var matchedTerms = 0

            if let resolvedSender {
                // Resolve a spoken/typed variant once. A second fuzzy match against
                // every message can admit unrelated senders with a shared name token.
                if let knownSender {
                    guard normalized(document.senderName) == normalized(knownSender) else { return nil }
                }
                let similarity = senderSimilarity(candidate: resolvedSender, document: document)
                guard similarity >= 0.72 else { return nil }
                score += Int(similarity * 70)
            }

            for term in terms {
                var matched = false
                if alias == term { score += 42; matched = true }
                if sender.contains(term) { score += 20; matched = true }
                if address.contains(term) { score += 18; matched = true }
                if subject.contains(term) { score += 12; matched = true }
                if searchable.contains(term) { score += 3; matched = true }
                if matched { matchedTerms += 1 }
            }

            guard matchedTerms >= requiredContentMatches else { return nil }
            if terms.count > 1, subject.contains(phrase) || searchable.contains(phrase) { score += 24 }
            if matchedTerms == terms.count { score += 24 }
            score += matchedTerms * 4
            score += min(learnedBoosts[document.id] ?? 0, 32)
            if document.receivedAt > Date.now.addingTimeInterval(-30 * 86_400) { score += 2 }
            return (document, score, matchedTerms)
        }

        return ranked.sorted { left, right in
            if left.2 != right.2 { return left.2 > right.2 }
            if left.1 != right.1 { return left.1 > right.1 }
            return left.0.receivedAt > right.0.receivedAt
        }
        .prefix(limit)
        .map(\.0.id)
    }

    static func bestSenderMatch(for candidate: String, in documents: [MailSearchDocument]) -> String? {
        knownSenderMatch(for: candidate, in: documents) ?? candidate
    }

    static func knownSenderMatch(for candidate: String, in documents: [MailSearchDocument]) -> String? {
        let cleaned = normalized(candidate)
        guard cleaned.count >= 2 else { return nil }

        let identities = Dictionary(grouping: documents, by: \.senderName).map { name, senderDocuments in
            let searchableIdentities = senderDocuments.flatMap { document in
                [
                    normalized(document.senderName),
                    normalized(document.senderAlias),
                    normalized(document.senderAddress.split(separator: "@").first.map(String.init) ?? "")
                ]
            }
            let similarity = searchableIdentities.map { nameSimilarity(cleaned, $0) }.max() ?? 0
            return (name, similarity)
        }
        let ranked = identities.sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            return left.0.count < right.0.count
        }
        guard let best = ranked.first, best.1 >= 0.70 else { return nil }
        return best.0
    }

    private static func explicitSenderCandidate(in query: String) -> String? {
        let lower = query.lowercased()
        let markers = [" emails from ", " email from ", " messages from ", " message from ", " mail from ", " from "]
        guard let match = markers.compactMap({ marker -> (Range<String.Index>, Int)? in
            lower.range(of: marker).map { ($0, marker.count) }
        }).sorted(by: { $0.0.lowerBound < $1.0.lowerBound }).first else { return nil }

        var candidate = String(query[match.0.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let stops = [
            " about ", " with ", " since ", " before ", " after ", " during ", " today",
            " this month", " this year", " last week", " last month", " past 7 days",
            " past 30 days", " last 7 days", " last 30 days", " that "
        ]
        let candidateLower = candidate.lowercased()
        if let stop = stops.compactMap({ candidateLower.range(of: $0)?.lowerBound }).min() {
            candidate = String(candidate[..<stop])
        }
        let result = candidate.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    private static func senderSimilarity(candidate: String, document: MailSearchDocument) -> Double {
        let target = normalized(candidate)
        return max(
            nameSimilarity(target, normalized(document.senderName)),
            nameSimilarity(target, normalized(document.senderAlias)),
            nameSimilarity(target, normalized(document.senderAddress.split(separator: "@").first.map(String.init) ?? ""))
        )
    }

    private static func nameSimilarity(_ left: String, _ right: String) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if right.contains(left) || left.contains(right) { return 0.94 }
        let leftWords = left.split(separator: " ").map(String.init)
        let rightWords = right.split(separator: " ").map(String.init)
        let bestWord = leftWords.flatMap { lhs in
            rightWords.map { rhs in max(editSimilarity(lhs, rhs), jaroWinklerSimilarity(lhs, rhs)) }
        }.max() ?? 0
        return max(bestWord, editSimilarity(left, right), jaroWinklerSimilarity(left, right))
    }

    /// Jaro-Winkler is deliberately paired with edit distance here. Names from
    /// speech recognition often preserve the beginning and phonetic shape while
    /// changing several interior vowels (for example, “Rilie” for “Riley”).
    /// Edit distance alone treats that as too weak a match.
    private static func jaroWinklerSimilarity(_ left: String, _ right: String) -> Double {
        let lhs = Array(left)
        let rhs = Array(right)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }

        let matchDistance = max(max(lhs.count, rhs.count) / 2 - 1, 0)
        var lhsMatches = Array(repeating: false, count: lhs.count)
        var rhsMatches = Array(repeating: false, count: rhs.count)
        var matches = 0

        for leftIndex in lhs.indices {
            let lower = max(0, leftIndex - matchDistance)
            let upper = min(leftIndex + matchDistance + 1, rhs.count)
            guard lower < upper else { continue }
            for rightIndex in lower..<upper where !rhsMatches[rightIndex] && lhs[leftIndex] == rhs[rightIndex] {
                lhsMatches[leftIndex] = true
                rhsMatches[rightIndex] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        let matchedLeft = lhs.indices.filter { lhsMatches[$0] }.map { lhs[$0] }
        let matchedRight = rhs.indices.filter { rhsMatches[$0] }.map { rhs[$0] }
        let transpositions = zip(matchedLeft, matchedRight).filter { $0 != $1 }.count / 2
        let matchCount = Double(matches)
        let jaro = (
            matchCount / Double(lhs.count) +
            matchCount / Double(rhs.count) +
            (matchCount - Double(transpositions)) / matchCount
        ) / 3
        let prefixLength = zip(lhs, rhs).prefix { $0 == $1 }.prefix(4).count
        return jaro + Double(prefixLength) * 0.1 * (1 - jaro)
    }

    private static func editSimilarity(_ left: String, _ right: String) -> Double {
        let lhs = Array(left)
        let rhs = Array(right)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = Array(0...rhs.count)
        for (row, leftCharacter) in lhs.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: rhs.count)
            for (column, rightCharacter) in rhs.enumerated() {
                current[column + 1] = min(
                    current[column] + 1,
                    previous[column + 1] + 1,
                    previous[column] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - (Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count)))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func minimumRequiredMatches(for termCount: Int) -> Int {
        switch termCount {
        case 0: 0
        case 1: 1
        case 2: 2
        default: max(2, Int(ceil(Double(termCount) * 0.6)))
        }
    }
}
