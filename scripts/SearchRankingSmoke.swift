import Foundation

private let now = Date()
private let fixtures = [
    MailSearchDocument(id: "energy", senderName: "Example Energy", senderAlias: "ad", senderAddress: "noreply@example.com", subject: "Action required: bank card update", searchableText: "energy distribution action required bank card update", receivedAt: now),
    MailSearchDocument(id: "network", senderName: "Example Network", senderAlias: "c", senderAddress: "noreply@example.org", subject: "example.org is now active", searchableText: "network network security performance", receivedAt: now.addingTimeInterval(-60)),
    MailSearchDocument(id: "software", senderName: "Example Software", senderAlias: "m", senderAddress: "account-security@example.net", subject: "Passkeys by default", searchableText: "software passkeys authentication", receivedAt: now.addingTimeInterval(-120)),
    MailSearchDocument(id: "domains", senderName: "Example Domains Renewals", senderAlias: "gr", senderAddress: "renewals@example.com", subject: "Domain renewal notice", searchableText: "domains domain renewal notice", receivedAt: now.addingTimeInterval(-180)),
    MailSearchDocument(id: "careers", senderName: "Example Careers", senderAlias: "li", senderAddress: "messages-noreply@example.org", subject: "Event Manager roles", searchableText: "careers event manager social fit hiring", receivedAt: now.addingTimeInterval(-240))
]

private let cases: [(String, [String])] = [
    ("show emails from Energy", ["energy"]),
    ("find Example Network security email", ["network"]),
    ("Example Software passkeys", ["software"]),
    ("Example Domains domain renewal", ["domains"]),
    ("quantum invoice", [])
]

var failures = 0
var priorResults = Set<String>()
for (query, expectedPrefix) in cases {
    let terms = MailSearchRanking.terms(in: query)
    let gmailQuery = MailSearchRanking.gmailQuery(for: terms)
    let results = MailSearchRanking.rankedIDs(documents: fixtures, terms: terms)
    print("QUERY: \(query) | GMAIL: \(gmailQuery) | RESULTS: \(results)")
    if Array(results.prefix(expectedPrefix.count)) != expectedPrefix {
        failures += 1
        print("FAIL: expected prefix \(expectedPrefix)")
    }
    if let first = results.first { priorResults.insert(first) }
}

if priorResults.count != 4 {
    failures += 1
    print("FAIL: distinct queries did not produce four distinct top results")
}

guard failures == 0 else { exit(1) }
print("PASS: search retrieval returned distinct, relevant sources and rejected the no-match query")
