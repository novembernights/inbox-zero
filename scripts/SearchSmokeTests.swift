import Foundation

@main
struct SearchSmokeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() {
        let documents = [
            MailSearchDocument(
                id: "riley-calendar",
                senderName: "Riley Example",
                senderAlias: "Riley",
                senderAddress: "riley@example.com",
                subject: "Gallery production meeting",
                searchableText: "Calendar invitation for the gallery production meeting.",
                receivedAt: now,
                hasAttachment: true,
                hasCalendarInvitation: true
            ),
            MailSearchDocument(
                id: "riley-render",
                senderName: "Riley Example",
                senderAlias: "Riley",
                senderAddress: "riley@example.com",
                subject: "Gallery renders",
                searchableText: "The revised renders are attached for review.",
                receivedAt: now.addingTimeInterval(-60),
                hasAttachment: true
            ),
            MailSearchDocument(
                id: "invoice",
                senderName: "Accounts Team",
                senderAlias: "Accounts",
                senderAddress: "billing@example.com",
                subject: "August invoice",
                searchableText: "Please find the invoice attached.",
                receivedAt: now.addingTimeInterval(-120),
                hasAttachment: true
            ),
            MailSearchDocument(
                id: "newsletter",
                senderName: "Studio Journal",
                senderAlias: "Studio",
                senderAddress: "hello@studio.example",
                subject: "Weekly journal",
                searchableText: "A text-only editorial newsletter.",
                receivedAt: now.addingTimeInterval(-30)
            )
        ]

        verify("show me email from Riley", documents: documents, expected: ["riley-calendar", "riley-render"])
        verify("show me email from Riley Example", documents: documents, expected: ["riley-calendar", "riley-render"])
        verify("show me email from Ryley", documents: documents, expected: ["riley-calendar", "riley-render"])
        verify("show me email from Rilie", documents: documents, expected: ["riley-calendar", "riley-render"])
        verify("show me all emails with attachments", documents: documents, expected: ["riley-calendar", "riley-render", "invoice"])
        verify("show every message with files", documents: documents, expected: ["riley-calendar", "riley-render", "invoice"])
        verify("show me all email with calendar invite", documents: documents, expected: ["riley-calendar"])
        verify("show calendar invitations", documents: documents, expected: ["riley-calendar"])
        verify("show emails from Rilie about Gallery", documents: documents, expected: ["riley-calendar", "riley-render"])
        verify("find the August invoice", documents: documents, expected: ["invoice"])
        verify("show recent emails", documents: documents, expected: ["riley-calendar", "newsletter", "riley-render", "invoice"])
        verify("show email from Nobody", documents: documents, expected: [])
        verifyInterpretation("show me email from Riley", attachment: false, calendar: false, timeScope: nil)
        verifyInterpretation("show me all emails with attachments", attachment: true, calendar: false, timeScope: nil)
        verifyInterpretation("show calendar invitations", attachment: true, calendar: true, timeScope: nil)
        verifyInterpretation("show me email from Riley today", attachment: false, calendar: false, timeScope: .today)
        print("PASS: search smoke suite")
    }

    private static func verify(_ query: String, documents: [MailSearchDocument], expected: [String]) {
        let interpreted = MailSearchRanking.interpret(query)
        let actual = MailSearchRanking.rankedIDs(
            documents: documents,
            terms: interpreted.contentTerms,
            senderCandidate: interpreted.senderCandidate,
            requiresAttachment: interpreted.requiresAttachment,
            requiresCalendarInvitation: interpreted.requiresCalendarInvitation,
            limit: interpreted.wantsAllMatches ? 100 : 6
        )
        precondition(actual == expected, "\(query): expected \(expected), got \(actual); interpreted=\(interpreted)")
    }

    private static func verifyInterpretation(
        _ query: String,
        attachment: Bool,
        calendar: Bool,
        timeScope: MailSearchTimeScope?
    ) {
        let result = MailSearchRanking.interpret(query)
        precondition(result.requiresAttachment == attachment, "\(query): unexpected attachment filter")
        precondition(result.requiresCalendarInvitation == calendar, "\(query): unexpected calendar filter")
        precondition(result.timeScope == timeScope, "\(query): unexpected time scope \(String(describing: result.timeScope))")
    }
}
