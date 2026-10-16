import Foundation

final class MailPersonalizationStore {
    private struct State: Codable {
        var searchAffinity: [String: [String: Int]] = [:]
        var queueChoices: [String: [String: Int]] = [:]
    }

    private let defaults: UserDefaults
    private let key = "inbox-zero-local-personalization-v1"
    private var state: State

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State()
        }
    }

    func recordSearchSelection(queryTerms: [String], message: InboxMessage) {
        guard let identity = searchIdentity(for: message), !queryTerms.isEmpty else { return }
        for term in queryTerms {
            var affinities = state.searchAffinity[term] ?? [:]
            affinities[identity] = min((affinities[identity] ?? 0) + 1, 20)
            state.searchAffinity[term] = affinities
        }
        save()
    }

    func searchBoosts(for documents: [MailSearchDocument], terms: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: documents.map { document in
            let identity = searchIdentity(for: document.senderAddress)
            let selections = terms.reduce(0) { total, term in
                total + (state.searchAffinity[term]?[identity] ?? 0)
            }
            return (document.id, min(selections * 4, 32))
        })
    }

    func recordQueueChoice(message: InboxMessage, queue: InboxQueue) {
        let identity = message.senderAddress.lowercased()
        guard !identity.isEmpty else { return }
        var choices = state.queueChoices[identity] ?? [:]
        choices[queue.rawValue] = min((choices[queue.rawValue] ?? 0) + 1, 20)
        state.queueChoices[identity] = choices
        save()
    }

    func preferredQueue(for message: InboxMessage) -> InboxQueue? {
        let identity = message.senderAddress.lowercased()
        guard let choices = state.queueChoices[identity] else { return nil }
        let ranked = choices.sorted { left, right in left.value > right.value }
        guard let leader = ranked.first,
              leader.value >= 2,
              leader.value >= (ranked.dropFirst().first?.value ?? 0) + 1 else { return nil }
        return InboxQueue(rawValue: leader.key)
    }

    private func searchIdentity(for message: InboxMessage) -> String? {
        let value = searchIdentity(for: message.senderAddress)
        return value.isEmpty ? nil : value
    }

    private func searchIdentity(for address: String) -> String {
        let lower = address.lowercased()
        guard let at = lower.lastIndex(of: "@") else { return lower }
        return String(lower[lower.index(after: at)...])
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
