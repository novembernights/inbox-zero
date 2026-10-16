import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum InboxCancellation {
    static func matches(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

@MainActor
final class GmailClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let tokenKey = "gmail-token"
    private let refreshKey = "gmail-refresh-token"
    private let emailKey = "gmail-account-email"
    private let accountsKey = "gmail-account-emails"
    private let clientIDKey = "gmail-oauth-client-id"
    private let accountClientIDKey = "gmail-oauth-client-id-account"
    private var webSession: ASWebAuthenticationSession?
    private(set) var accountSyncErrors: [String: String] = [:]

    var clientID: String {
        if let saved = Keychain.read(clientIDKey), !saved.isEmpty { return saved }
        return Bundle.main.object(forInfoDictionaryKey: "GMAIL_CLIENT_ID") as? String ?? ""
    }
    var redirectScheme: String { redirectScheme(for: clientID) }

    private func redirectScheme(for clientID: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        if clientID.hasSuffix(suffix) {
            return "com.googleusercontent.apps." + String(clientID.dropLast(suffix.count))
        }
        return Bundle.main.object(forInfoDictionaryKey: "GMAIL_REDIRECT_SCHEME") as? String ?? ""
    }
    var isConfigured: Bool { !clientID.isEmpty && !redirectScheme.isEmpty && !clientID.hasPrefix("SET_") }
    var storedAccountEmails: [String] {
        if let accounts = UserDefaults.standard.stringArray(forKey: accountsKey), !accounts.isEmpty { return accounts }
        return UserDefaults.standard.string(forKey: emailKey).map { [$0] } ?? []
    }
    var hasCredentials: Bool {
        storedAccountEmails.contains { credential(tokenKey, for: $0) != nil || credential(refreshKey, for: $0) != nil }
    }
    var storedAccountEmail: String? { storedAccountEmails.first }

    /// Starts or renews Gmail push delivery without moving message contents or
    /// OAuth credentials off-device.
    func renewPushWatches(topicName: String) async throws -> [String: Date] {
        guard !topicName.isEmpty else { return [:] }
        var expirations: [String: Date] = [:]
        for email in storedAccountEmails {
            let token = try await validAccessToken(for: email)
            var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/watch")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(GmailWatchRequest(topicName: topicName))
            let response: GmailWatchResponse = try await decode(request)
            if let milliseconds = Double(response.expiration) {
                expirations[email] = Date(timeIntervalSince1970: milliseconds / 1_000)
            }
        }
        return expirations
    }

    func configureOAuth(clientID rawClientID: String) throws {
        let value = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix(".apps.googleusercontent.com"),
              value.count > ".apps.googleusercontent.com".count else {
            throw GmailError.invalidClientID
        }
        try Keychain.write(value, key: clientIDKey)
    }

    func signIn(using requestedClientID: String? = nil, expectedEmail: String? = nil) async throws -> String {
        let selectedClientID = requestedClientID ?? clientID
        let selectedRedirectScheme = redirectScheme(for: selectedClientID)
        guard !selectedClientID.isEmpty, !selectedRedirectScheme.isEmpty else { throw GmailError.notConfigured }
        let verifier = Self.randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: selectedClientID), .init(name: "redirect_uri", value: "\(selectedRedirectScheme):/oauth2redirect"),
            .init(name: "response_type", value: "code"), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "select_account consent"), .init(name: "scope", value: "openid email https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.compose")
        ]
        let callback = try await authenticate(url: components.url!, callbackScheme: selectedRedirectScheme)
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else { throw GmailError.invalidCallback }
        let token = try await exchange(code: code, verifier: verifier, clientID: selectedClientID, redirectScheme: selectedRedirectScheme)
        let email = try await fetchProfileEmail(token: token.accessToken)
        if let expectedEmail, email.caseInsensitiveCompare(expectedEmail) != .orderedSame {
            throw GmailError.accountMismatch(expected: expectedEmail, actual: email)
        }
        try Keychain.write(token.accessToken, key: accountKey(tokenKey, email: email))
        if let refresh = token.refreshToken { try Keychain.write(refresh, key: accountKey(refreshKey, email: email)) }
        try Keychain.write(selectedClientID, key: accountKey(accountClientIDKey, email: email))
        var accounts = storedAccountEmails.filter { $0.caseInsensitiveCompare(email) != .orderedSame }
        accounts.append(email)
        if let primary = storedAccountEmail,
           let primaryIndex = accounts.firstIndex(where: { $0.caseInsensitiveCompare(primary) == .orderedSame }) {
            let primaryAccount = accounts.remove(at: primaryIndex)
            accounts.insert(primaryAccount, at: 0)
        }
        UserDefaults.standard.set(accounts, forKey: accountsKey)
        UserDefaults.standard.set(email, forKey: emailKey)
        return email
    }

    func signOut() {
        for email in storedAccountEmails {
            Keychain.delete(accountKey(tokenKey, email: email))
            Keychain.delete(accountKey(refreshKey, email: email))
            Keychain.delete(accountKey(accountClientIDKey, email: email))
        }
        Keychain.delete(tokenKey); Keychain.delete(refreshKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
        UserDefaults.standard.removeObject(forKey: accountsKey)
    }

    func fetchMessages(since: Date? = nil) async throws -> [InboxMessage] {
        var combined: [InboxMessage] = []
        var successfulAccounts = 0
        var failures: [String: String] = [:]
        for email in storedAccountEmails {
            do {
                let token = try await validAccessToken(for: email)
                let query = since.map { "after:\(Int($0.addingTimeInterval(-300).timeIntervalSince1970))" }
                // A fresh install needs more than Gmail's first page or All Mail and
                // local Ask results appear incomplete. Incremental refreshes stay small.
                let limit = since == nil ? 500 : 50
                let listed = try await listMessageIDs(token: token, query: query, limit: limit)
                combined.append(contentsOf: try await fetchListed(listed, token: token, accountEmail: email))
                successfulAccounts += 1
            } catch {
                if InboxCancellation.matches(error) { throw CancellationError() }
                failures[email] = error.localizedDescription
            }
        }
        accountSyncErrors = failures
        if successfulAccounts == 0, let message = failures.values.first { throw GmailError.requestFailed(message) }
        return combined.sorted { $0.receivedAt > $1.receivedAt }
    }

    func searchMessages(query: String, limit: Int = 100) async throws -> [InboxMessage] {
        var combined: [InboxMessage] = []
        for email in storedAccountEmails {
            do {
                let token = try await validAccessToken(for: email)
                let listed = try await listMessageIDs(token: token, query: query, limit: limit)
                combined.append(contentsOf: try await fetchListed(listed, token: token, accountEmail: email))
            } catch {
                if InboxCancellation.matches(error) { throw CancellationError() }
                accountSyncErrors[email] = error.localizedDescription
            }
        }
        return combined.sorted { $0.receivedAt > $1.receivedAt }
    }

    private func listMessageIDs(token: String, query: String?, limit: Int) async throws -> [GmailListItem] {
        var result: [GmailListItem] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            var items = [URLQueryItem(name: "maxResults", value: String(min(100, limit - result.count)))]
            if let query, !query.isEmpty { items.append(.init(name: "q", value: query)) }
            if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            let page: GmailList = try await request(components.url!.absoluteString, token: token)
            result.append(contentsOf: page.messages ?? [])
            pageToken = page.nextPageToken
        } while result.count < limit && pageToken != nil
        return Array(result.prefix(limit))
    }

    func downloadAttachment(from message: InboxMessage, attachmentID: String) async throws -> Data {
        let token = try await validAccessToken(for: message.accountEmail ?? storedAccountEmail)
        let resource: GmailAttachmentResource = try await request(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(message.gmailMessageID ?? message.id)/attachments/\(attachmentID)",
            token: token
        )
        guard let data = resource.data.base64URLDecoded else {
            throw GmailError.requestFailed("Gmail returned an unreadable attachment.")
        }
        return data
    }

    private func fetchListed(_ items: [GmailListItem], token: String, accountEmail: String) async throws -> [InboxMessage] {
        let labelQueues = Dictionary(uniqueKeysWithValues: try await inboxLabels(token: token).compactMap { label -> (String, InboxQueue)? in
            guard label.name.hasPrefix("inbox.Zer0/"), let queue = InboxQueue(rawValue: String(label.name.dropFirst("inbox.Zer0/".count))) else { return nil }
            return (label.id, queue)
        })
        var result: [InboxMessage] = []
        let maximumConcurrentRequests = 5
        for start in stride(from: 0, to: items.count, by: maximumConcurrentRequests) {
            let end = min(start + maximumConcurrentRequests, items.count)
            let batch = items[start..<end]
            let fetched = try await withThrowingTaskGroup(of: InboxMessage?.self) { group in
                for item in batch {
                    group.addTask {
                        try await self.fetchMessage(id: item.id, token: token, labelQueues: labelQueues, accountEmail: accountEmail)
                    }
                }
                var messages: [InboxMessage] = []
                for try await message in group {
                    if let message { messages.append(message) }
                }
                return messages
            }
            result.append(contentsOf: fetched)
        }
        return result.sorted { $0.receivedAt > $1.receivedAt }
    }

    func apply(queue: InboxQueue, to message: InboxMessage) async throws {
        guard isConfigured, hasCredentials else { return }
        let token = try await validAccessToken(for: message.accountEmail ?? storedAccountEmail)
        let label = "inbox.Zer0/\(queue.rawValue)"
        let labelID = try await ensureLabel(named: label, token: token)
        let labels = try await inboxLabels(token: token)
        let oldIDs = labels.filter { $0.name.hasPrefix("inbox.Zer0/") }.map(\.id)
        let body = ModifyRequest(addLabelIds: [labelID], removeLabelIds: oldIDs.filter { $0 != labelID })
        let remoteID = message.gmailMessageID ?? message.id
        let _: GmailMessageResource = try await request("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(remoteID)/modify", method: "POST", token: token, body: body)
    }

    func trash(_ message: InboxMessage) async throws {
        guard isConfigured, hasCredentials else { throw GmailError.previewCannotSend }
        let token = try await validAccessToken(for: message.accountEmail ?? storedAccountEmail)
        let remoteID = message.gmailMessageID ?? message.id
        let _: GmailMessageResource = try await request(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(remoteID)/trash",
            method: "POST",
            token: token
        )
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
        guard isConfigured, hasCredentials else { throw GmailError.previewCannotSend }
        guard !to.isEmpty, (to + cc + bcc).allSatisfy({ $0.contains("@") }) else {
            throw GmailError.invalidRecipient
        }
        let token = try await validAccessToken(for: account)
        let mime = Self.mimeMessage(
            to: to.joined(separator: ", "),
            cc: cc.joined(separator: ", "),
            bcc: bcc.joined(separator: ", "),
            subject: subject,
            body: body,
            attachments: attachments
        )
        let payload = SendRequest(raw: Data(mime.utf8).base64URLEncoded, threadId: nil)
        let _: GmailMessageResource = try await request(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
            method: "POST",
            token: token,
            body: payload
        )
    }

    func sendReply(to message: InboxMessage, body: String, attachments: [OutgoingAttachment]) async throws {
        guard isConfigured, hasCredentials else { throw GmailError.previewCannotSend }
        let token = try await validAccessToken(for: message.accountEmail ?? storedAccountEmail)
        let recipient = message.replyTo?.address ?? message.senderAddress
        let mime = Self.mimeMessage(to: recipient, subject: "Re: \(message.subject)", body: body, attachments: attachments)
        let payload = SendRequest(raw: Data(mime.utf8).base64URLEncoded, threadId: message.threadID)
        let _: GmailMessageResource = try await request("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", method: "POST", token: token, body: payload)
    }

    func sendReplyAll(to message: InboxMessage, body: String, attachments: [OutgoingAttachment]) async throws {
        guard isConfigured, hasCredentials else { throw GmailError.previewCannotSend }
        let token = try await validAccessToken(for: message.accountEmail ?? storedAccountEmail)
        let ownAddress = (message.accountEmail ?? storedAccountEmail ?? "").lowercased()
        let primaryAddress = message.replyTo?.address ?? message.senderAddress

        var seen = Set<String>()
        func uniqueAddresses(_ addresses: [String]) -> [String] {
            addresses.compactMap { value in
                let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = address.lowercased()
                guard !address.isEmpty, key != ownAddress, seen.insert(key).inserted else { return nil }
                return address
            }
        }

        let to = uniqueAddresses([primaryAddress] + (message.toRecipients ?? []).map(\.address))
        let cc = uniqueAddresses((message.ccRecipients ?? []).map(\.address))
        let mime = Self.mimeMessage(
            to: to.joined(separator: ", "),
            cc: cc.joined(separator: ", "),
            subject: "Re: \(message.subject)",
            body: body,
            attachments: attachments
        )
        let payload = SendRequest(raw: Data(mime.utf8).base64URLEncoded, threadId: message.threadID)
        let _: GmailMessageResource = try await request("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", method: "POST", token: token, body: payload)
    }

    func forward(_ message: InboxMessage, to recipient: String, body: String, attachments: [OutgoingAttachment]) async throws {
        guard isConfigured, hasCredentials else { throw GmailError.previewCannotSend }
        guard recipient.contains("@") else { throw GmailError.invalidRecipient }
        let token = try await validAccessToken(for: message.accountEmail ?? storedAccountEmail)
        let note = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteHTML = note.isEmpty
            ? ""
            : "<div>\(Self.htmlEscaped(note).replacingOccurrences(of: "\n", with: "<br>"))</div><br>"
        let originalHTML = message.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "<p>\(Self.htmlEscaped(message.snippet))</p>"
            : message.bodyHTML
        let forwardedHTML = """
        <!doctype html>
        <html><body>
        \(noteHTML)
        <div style="color:#666;font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px;line-height:1.45">
          <div>---------- Forwarded message ----------</div>
          <div><strong>From:</strong> \(Self.htmlEscaped(message.senderName)) &lt;\(Self.htmlEscaped(message.senderAddress))&gt;</div>
          <div><strong>Date:</strong> \(Self.htmlEscaped(message.receivedAt.formatted(date: .long, time: .shortened)))</div>
          <div><strong>Subject:</strong> \(Self.htmlEscaped(message.subject))</div>
        </div>
        <br>
        \(originalHTML)
        </body></html>
        """
        let plainFallback = "\(note)\(note.isEmpty ? "" : "\n\n")---------- Forwarded message ----------\nFrom: \(message.senderName) <\(message.senderAddress)>\nDate: \(message.receivedAt.formatted(date: .long, time: .shortened))\nSubject: \(message.subject)\n\n\(message.snippet)"
        let mime = Self.mimeMessage(
            to: recipient,
            subject: "Fwd: \(message.subject)",
            body: plainFallback,
            htmlBody: forwardedHTML,
            attachments: attachments
        )
        let payload = SendRequest(raw: Data(mime.utf8).base64URLEncoded, threadId: nil)
        let _: GmailMessageResource = try await request("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", method: "POST", token: token, body: payload)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return scene.keyWindow ?? ASPresentationAnchor(windowScene: scene)
        }
        preconditionFailure("Gmail sign-in requires an active window scene")
    }

    private func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: GmailError.invalidCallback) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            session.start()
        }
    }

    private func exchange(code: String, verifier: String, clientID: String, redirectScheme: String) async throws -> OAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["client_id": clientID, "code": code, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": "\(redirectScheme):/oauth2redirect"]
        request.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }.joined(separator: "&").data(using: .utf8)
        return try await decode(request)
    }

    private func validAccessToken(for requestedEmail: String?) async throws -> String {
        guard let email = requestedEmail ?? storedAccountEmail else { throw GmailError.notSignedIn }
        // Google access tokens are short lived. Prefer exchanging the durable
        // refresh token instead of treating an old Keychain value as permanent.
        guard let refresh = credential(refreshKey, for: email) else {
            if let token = credential(tokenKey, for: email) { return token }
            throw GmailError.notSignedIn
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let refreshClientID = clientID(for: email)
        request.httpBody = "client_id=\(refreshClientID)&refresh_token=\(refresh)&grant_type=refresh_token".data(using: .utf8)
        do {
            let token: OAuthToken = try await decode(request)
            try Keychain.write(token.accessToken, key: accountKey(tokenKey, email: email))
            return token.accessToken
        } catch GmailError.authenticationExpired {
            Keychain.delete(accountKey(tokenKey, email: email))
            Keychain.delete(accountKey(refreshKey, email: email))
            throw GmailError.authenticationExpired
        }
    }

    private func fetchProfileEmail(token: String) async throws -> String {
        let profile: GmailProfile = try await request("https://gmail.googleapis.com/gmail/v1/users/me/profile", token: token)
        return profile.emailAddress
    }

    private func fetchMessage(id: String, token: String, labelQueues: [String: InboxQueue], accountEmail: String) async throws -> InboxMessage? {
        let resource: GmailMessageResource = try await request("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full", token: token)
        var headers: [String: String] = [:]
        for header in resource.payload?.headers ?? [] {
            let name = header.name.lowercased()
            if headers[name] == nil { headers[name] = header.value }
        }
        let from = headers["from"] ?? "Unknown sender"
        let address = from.matches(of: /<([^>]+)>/).first.map { String($0.1) } ?? from
        let name = (from.split(separator: "<", maxSplits: 1).first.map(String.init) ?? from)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let html = resource.payload?.decodedBody ?? "<p>\(resource.snippet ?? "")</p>"
        let toRecipients = Self.mailParticipants(in: headers["to"])
        let ccRecipients = Self.mailParticipants(in: headers["cc"])
        let bccRecipients = Self.mailParticipants(in: headers["bcc"])
        let replyTo = Self.mailParticipants(in: headers["reply-to"]).first
        let timestamp = Double(resource.internalDate ?? "") ?? Date.now.timeIntervalSince1970 * 1000
        let matchedQueue = resource.labelIds?.compactMap { labelQueues[$0] }.first
        let primary = storedAccountEmail
        let localID = accountEmail.caseInsensitiveCompare(primary ?? accountEmail) == .orderedSame
            ? resource.id
            : "\(accountEmail.lowercased())|\(resource.id)"
        return InboxMessage(id: localID, threadID: resource.threadId ?? resource.id, senderName: name.isEmpty ? address : name, senderAddress: address, subject: headers["subject"] ?? "No subject", snippet: resource.snippet ?? "", bodyHTML: html, receivedAt: Date(timeIntervalSince1970: timestamp / 1000), queue: matchedQueue ?? .action, isVerified: Self.verifiedDomains.contains(address.split(separator: "@").last.map(String.init) ?? ""), summary: nil, suggestedReply: nil, participatesInWorkflow: matchedQueue != nil, attachments: resource.payload?.inboxAttachments(excludingInlineReferencesIn: html) ?? [], senderLogoURL: Self.senderLogoURL(in: html), isInbox: resource.labelIds?.contains("INBOX") == true, accountEmail: accountEmail, gmailMessageID: resource.id, mailProvider: .gmail, rfcMessageID: headers["message-id"], toRecipients: toRecipients, ccRecipients: ccRecipients, bccRecipients: bccRecipients, replyTo: replyTo)
    }

    private static func mailParticipants(in header: String?) -> [MailParticipant] {
        guard let header, !header.isEmpty else { return [] }
        return header
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { rawValue in
                let value = String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                if let match = value.wholeMatch(of: /\s*"?([^"<]*)"?\s*<([^>]+)>\s*/) {
                    let name = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                    let address = String(match.2).trimmingCharacters(in: .whitespacesAndNewlines)
                    return MailParticipant(name: name, address: address)
                }
                return MailParticipant(name: "", address: value.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")))
            }
    }

    private func inboxLabels(token: String) async throws -> [GmailLabel] {
        let response: GmailLabels = try await request("https://gmail.googleapis.com/gmail/v1/users/me/labels", token: token); return response.labels
    }

    private func ensureLabel(named name: String, token: String) async throws -> String {
        if let label = try await inboxLabels(token: token).first(where: { $0.name == name }) { return label.id }
        let created: GmailLabel = try await request("https://gmail.googleapis.com/gmail/v1/users/me/labels", method: "POST", token: token, body: CreateLabel(name: name, labelListVisibility: "labelShow", messageListVisibility: "show")); return created.id
    }

    private func request<T: Decodable>(_ url: String, method: String = "GET", token: String, body: (any Encodable)? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(AnyEncodable(body)) }
        for attempt in 0..<3 {
            do {
                return try await decode(request)
            } catch GmailError.rateLimited where attempt < 2 {
                let delay = UInt64(1 << attempt) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw GmailError.rateLimited
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailError.requestFailed("Google did not return a valid response.") }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 401 { throw GmailError.authenticationExpired }
            if let oauthError = try? JSONDecoder().decode(OAuthErrorEnvelope.self, from: data),
               oauthError.error == "invalid_grant" || oauthError.error == "invalid_token" {
                throw GmailError.authenticationExpired
            }
            let googleError = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data)
            if http.statusCode == 403,
               googleError?.error.errors?.contains(where: { $0.reason == "accessNotConfigured" }) == true {
                throw GmailError.apiNotEnabled
            }
            let reasons = googleError?.error.errors?.compactMap(\.reason) ?? []
            if http.statusCode == 429 || reasons.contains("userRateLimitExceeded") || reasons.contains("rateLimitExceeded") {
                throw GmailError.rateLimited
            }
            let message = googleError?.error.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GmailError.requestFailed(message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static let verifiedDomains: Set<String> = ["nike.com", "emiratesnbd.com", "revolut.com"]
    private func accountKey(_ base: String, email: String) -> String {
        "\(base):\(email.lowercased())"
    }

    private func credential(_ base: String, for email: String) -> String? {
        if let accountValue = Keychain.read(accountKey(base, email: email)) { return accountValue }
        if email.caseInsensitiveCompare(storedAccountEmails.first ?? email) == .orderedSame {
            return Keychain.read(base)
        }
        return nil
    }

    private func clientID(for email: String) -> String {
        if let saved = Keychain.read(accountKey(accountClientIDKey, email: email)), !saved.isEmpty { return saved }
        return clientID
    }

    private static func randomURLSafeString() -> String { Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded }

    private static func senderLogoURL(in html: String) -> String? {
        let pattern = #"<img[^>]+src\s*=\s*[\"']([^\"']+)[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        let candidates = expression.matches(in: html, range: range).compactMap { match -> String? in
            guard match.numberOfRanges > 1, let sourceRange = Range(match.range(at: 1), in: html) else { return nil }
            let source = String(html[sourceRange]).replacingOccurrences(of: "&amp;", with: "&")
            guard source.lowercased().hasPrefix("https://") else { return nil }
            return source
        }
        return candidates
            .map { source -> (String, Int) in
                let lower = source.lowercased()
                var score = 0
                if lower.contains("logo") { score += 12 }
                if lower.contains("brand") { score += 7 }
                if lower.contains("header") || lower.contains("masthead") { score += 4 }
                if lower.contains("favicon") { score += 5 }
                if lower.contains("pixel") || lower.contains("track") || lower.contains("beacon") || lower.contains("open.") { score -= 20 }
                return (source, score)
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    private static func mimeMessage(
        to recipient: String,
        cc: String = "",
        bcc: String = "",
        subject: String,
        body: String,
        htmlBody: String? = nil,
        attachments: [OutgoingAttachment]
    ) -> String {
        let recipientHeaders = "To: \(recipient)\r\n"
            + (cc.isEmpty ? "" : "Cc: \(cc)\r\n")
            + (bcc.isEmpty ? "" : "Bcc: \(bcc)\r\n")
        guard !attachments.isEmpty else {
            if let htmlBody {
                return "\(recipientHeaders)Subject: \(subject)\r\nMIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(htmlBody)"
            }
            return "\(recipientHeaders)Subject: \(subject)\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(body)"
        }
        let boundary = "inboxZer0-\(UUID().uuidString)"
        var mime = "\(recipientHeaders)Subject: \(subject)\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        if let htmlBody {
            mime += "--\(boundary)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(htmlBody)\r\n"
        } else {
            mime += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(body)\r\n"
        }
        for attachment in attachments {
            let safeName = attachment.filename.replacingOccurrences(of: "\"", with: "")
            mime += "--\(boundary)\r\nContent-Type: \(attachment.mimeType); name=\"\(safeName)\"\r\nContent-Disposition: attachment; filename=\"\(safeName)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            mime += attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n"
        }
        mime += "--\(boundary)--\r\n"
        return mime
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private enum GmailError: LocalizedError {
    case notConfigured, invalidClientID, invalidCallback, notSignedIn, authenticationExpired, accountMismatch(expected: String, actual: String), apiNotEnabled, rateLimited, previewCannotSend, invalidRecipient, requestFailed(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set up Gmail OAuth in Settings before connecting."
        case .invalidClientID: "Enter a valid Google iOS OAuth client ID ending in .apps.googleusercontent.com."
        case .invalidCallback: "Google returned an invalid sign-in response."
        case .notSignedIn: "Connect a Gmail account first."
        case .authenticationExpired: "Your Gmail session has expired. Connect Gmail again to continue."
        case .accountMismatch(let expected, let actual): "This connection is configured for \(expected), but Google returned \(actual). Choose the correct Google account and try again."
        case .apiNotEnabled: "Google sign-in succeeded, but the Gmail API is not enabled for this Google Cloud project. Enable the Gmail API, wait a minute, then tap Sync now."
        case .rateLimited: "Gmail is temporarily limiting requests. inbox.Zerø will slow down automatically; wait a moment, then tap Sync now."
        case .previewCannotSend: "Connect Gmail before sending a message."
        case .invalidRecipient: "Enter a valid recipient email address."
        case .requestFailed(let detail): "Gmail request failed: \(detail)"
        }
    }
}

// Shared by the mail client and optional push relay; credentials remain device-local.
enum Keychain {
    static func write(_ value: String, key: String) throws {
        delete(key)
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Bundle.main.bundleIdentifier ?? "inbox.Zer0", kSecAttrAccount as String: key, kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw GmailError.requestFailed("Unable to save credentials") }
    }
    static func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Bundle.main.bundleIdentifier ?? "inbox.Zer0", kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8)
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Bundle.main.bundleIdentifier ?? "inbox.Zer0", kSecAttrAccount as String: key] as CFDictionary)
    }
}

private struct AnyEncodable: Encodable { let encodeBlock: (Encoder) throws -> Void; init(_ value: any Encodable) { encodeBlock = value.encode }; func encode(to encoder: Encoder) throws { try encodeBlock(encoder) } }
private struct OAuthToken: Codable { let accessToken: String; let refreshToken: String?; enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token" } }
private struct GmailProfile: Codable { let emailAddress: String }
private struct GmailWatchRequest: Codable { let topicName: String }
private struct GmailWatchResponse: Codable { let historyId: String; let expiration: String }
private struct GoogleErrorEnvelope: Codable { let error: GoogleErrorBody }
private struct GoogleErrorBody: Codable { let code: Int; let message: String; let errors: [GoogleErrorItem]? }
private struct GoogleErrorItem: Codable { let reason: String? }
private struct OAuthErrorEnvelope: Codable { let error: String; let errorDescription: String?; enum CodingKeys: String, CodingKey { case error, errorDescription = "error_description" } }
private struct GmailList: Codable {
    let messages: [GmailListItem]?
    let nextPageToken: String?
}
private struct GmailListItem: Codable { let id: String }
private struct GmailLabels: Codable { let labels: [GmailLabel] }
private struct GmailLabel: Codable { let id: String; let name: String }
private struct CreateLabel: Codable { let name, labelListVisibility, messageListVisibility: String }
private struct ModifyRequest: Codable { let addLabelIds, removeLabelIds: [String] }
private struct SendRequest: Codable { let raw: String; let threadId: String? }
private struct GmailHeader: Codable { let name, value: String }
private struct GmailPayload: Codable {
    let mimeType: String?; let filename: String?; let body: GmailBody?; let parts: [GmailPayload]?; let headers: [GmailHeader]?
    var decodedBody: String? {
        if mimeType == "text/html", let data = body?.data?.base64URLDecoded { return String(data: data, encoding: .utf8) }
        return parts?.compactMap(\.decodedBody).first
    }
    func inboxAttachments(excludingInlineReferencesIn html: String) -> [InboxAttachment] {
        var result = parts?.flatMap { $0.inboxAttachments(excludingInlineReferencesIn: html) } ?? []
        if let filename, !filename.isEmpty, let attachmentID = body?.attachmentId {
            let headerValues = Dictionary(
                headers?.map { ($0.name.lowercased(), $0.value) } ?? [],
                uniquingKeysWith: { first, _ in first }
            )
            let identifiers = [headerValues["content-id"], headerValues["x-attachment-id"]].compactMap { $0 }
            guard !MIMEAttachmentPolicy.shouldHideAsInlineBodyAsset(
                mimeType: mimeType ?? "application/octet-stream",
                disposition: headerValues["content-disposition"],
                contentIdentifiers: identifiers,
                html: html
            ) else { return result }
            result.insert(
                InboxAttachment(
                    id: attachmentID,
                    filename: filename,
                    mimeType: mimeType ?? "application/octet-stream",
                    size: body?.size ?? 0
                ),
                at: 0
            )
        }
        return result
    }
}
private struct GmailBody: Codable { let data: String?; let attachmentId: String?; let size: Int? }
private struct GmailAttachmentResource: Codable { let data: String; let size: Int? }
private struct GmailMessageResource: Codable { let id: String; let threadId: String?; let labelIds: [String]?; let snippet: String?; let internalDate: String?; let payload: GmailPayload? }
private extension Data { var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
private extension String { var base64URLDecoded: Data? { var value = replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); value += String(repeating: "=", count: (4 - value.count % 4) % 4); return Data(base64Encoded: value) } }
