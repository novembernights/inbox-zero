import EventKit
import Foundation
import Observation

@MainActor
@Observable
final class DailyContextService {
    private let eventStore = EKEventStore()

    private(set) var calendarEventCount = 0
    private(set) var nextEventTitle: String?
    private(set) var calendarFreeTimeSummary: String?
    private(set) var isRefreshing = false
    var errorMessage: String?

    var calendarConnected: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func start() async {
        await refresh()
    }

    func requestCalendarAccess() async {
        do {
            guard try await eventStore.requestFullAccessToEvents() else { return }
            await refreshCalendar()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshCalendar()
    }

    private func refreshCalendar() async {
        guard calendarConnected else {
            calendarEventCount = 0
            nextEventTitle = nil
            calendarFreeTimeSummary = nil
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? .now
        let events = eventStore.events(matching: eventStore.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > Date.now }
            .sorted { $0.startDate < $1.startDate }
        calendarEventCount = events.count
        nextEventTitle = events.first?.title
        calendarFreeTimeSummary = freeTimeSummary(for: events)
    }

    private func freeTimeSummary(for events: [EKEvent]) -> String {
        let calendar = Calendar.current
        let now = Date.now
        let dayEnd = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: now) ?? now
        guard dayEnd > now else { return "Your calendar is clear for the rest of today." }
        guard !events.isEmpty else { return "You’re mostly free for the rest of today." }

        var cursor = now
        var windows: [(start: Date, duration: TimeInterval)] = []
        for event in events {
            if event.startDate > cursor {
                windows.append((cursor, event.startDate.timeIntervalSince(cursor)))
            }
            cursor = max(cursor, event.endDate)
        }
        if cursor < dayEnd { windows.append((cursor, dayEnd.timeIntervalSince(cursor))) }
        guard let longest = windows.max(by: { $0.duration < $1.duration }), longest.duration >= 90 * 60 else {
            return "Your calendar stays fairly full through the evening."
        }
        let time = longest.start.formatted(.dateTime.hour().minute())
        if longest.duration >= 2 * 60 * 60, longest.start >= (events.last?.endDate ?? now) {
            return "You’re mostly free after \(time)."
        }
        let hours = Int(longest.duration / 3_600)
        let minutes = Int(longest.duration.truncatingRemainder(dividingBy: 3_600) / 60)
        let duration = hours > 0 ? "\(hours) hr \(minutes > 0 ? "\(minutes) min" : "")" : "\(minutes) min"
        return "Your longest free window is \(duration.trimmingCharacters(in: .whitespaces)) from \(time)."
    }

}
