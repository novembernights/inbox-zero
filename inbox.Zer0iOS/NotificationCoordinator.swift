import UIKit
import UserNotifications
import BackgroundTasks

@MainActor
final class PushRelayCoordinator {
    static let shared = PushRelayCoordinator()

    private var deviceToken: String?
    private var registrationTask: Task<Void, Never>?

    private var relayURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PUSH_RELAY_BASE_URL") as? String,
              !raw.isEmpty,
              !raw.hasPrefix("SET_"),
              let url = URL(string: raw) else { return nil }
        return url
    }

    private var topicName: String {
        Bundle.main.object(forInfoDictionaryKey: "GMAIL_PUSH_TOPIC") as? String ?? ""
    }

    private var registrationToken: String? {
        // A private development relay credential must not be compiled into a bundle.
        guard let value = Keychain.read("push-relay-registration-token"),
              !value.isEmpty,
              !value.hasPrefix("SET_") else { return nil }
        return value
    }

    func received(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        scheduleRegistration()
    }

    func accountStateChanged() {
        scheduleRegistration()
    }

    private func scheduleRegistration() {
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            await self?.registerIfPossible()
        }
    }

    private func registerIfPossible() async {
        guard !Task.isCancelled,
              let relayURL,
              let registrationToken,
              let deviceToken,
              let gmail = MobileAppDelegate.store?.gmail else { return }
        let accounts = gmail.storedAccountEmails
        guard !accounts.isEmpty else { return }

        do {
            let expirations = try await gmail.renewPushWatches(topicName: topicName)
            var request = URLRequest(url: relayURL.appending(path: "v1/devices/register"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(registrationToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(
                PushRegistration(
                    deviceToken: deviceToken,
                    bundleID: Bundle.main.bundleIdentifier ?? "org.example.inboxzero.ios",
                    environment: _isDebugAssertConfiguration() ? "sandbox" : "production",
                    accounts: accounts,
                    watchExpirations: expirations.mapValues(\.timeIntervalSince1970)
                )
            )
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            UserDefaults.standard.set(Date.now, forKey: "inbox-zero-push-relay-registered-at")
        } catch {
            // Retry on the next token, account, or foreground transition without
            // interrupting normal mailbox operation.
        }
    }
}

private struct PushRegistration: Codable {
    let deviceToken: String
    let bundleID: String
    let environment: String
    let accounts: [String]
    let watchExpirations: [String: TimeInterval]
}

@MainActor
enum InboxNotificationCoordinator {
    private static let notifiedMessageIDsKey = "inbox-zero-notified-message-ids"

    static func deliverNewMail(_ messages: [InboxMessage]) async {
        guard !messages.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        var notifiedIDs = Set(UserDefaults.standard.stringArray(forKey: notifiedMessageIDsKey) ?? [])
        for message in messages.sorted(by: { $0.receivedAt < $1.receivedAt }) where !notifiedIDs.contains(message.id) {
            let content = UNMutableNotificationContent()
            content.title = message.senderName
            content.subtitle = "\(MailboxPersona.name(for: message.accountEmail)) · \(message.queue.rawValue)"
            content.body = message.subject
            content.sound = .default
            content.threadIdentifier = message.accountEmail ?? "inbox.Zer0"
            content.categoryIdentifier = "INBOX_ZERO_NEW_MAIL"

            let request = UNNotificationRequest(
                identifier: "inbox-zero-mail-\(message.id)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
                notifiedIDs.insert(message.id)
            } catch {
                continue
            }
        }

        // Keep enough history to prevent duplicate alerts without allowing this preference
        // to grow indefinitely over the lifetime of the mailbox.
        let retainedIDs = messages.map(\.id) + notifiedIDs.filter { id in
            !messages.contains(where: { $0.id == id })
        }
        UserDefaults.standard.set(Array(retainedIDs.prefix(500)), forKey: notifiedMessageIDsKey)
    }
}

@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var store: InboxStore?
    private static let mailRefreshIdentifier = (Bundle.main.bundleIdentifier ?? "org.example.inboxzero.ios") + ".mail-refresh"
    private var backgroundSyncTask: Task<Void, Never>?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.mailRefreshIdentifier, using: nil) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in self?.handleMailRefresh(refreshTask) }
        }
#if !targetEnvironment(simulator)
        Task {
            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted == true { application.registerForRemoteNotifications() }
        }
#endif
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleMailRefresh()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        PushRelayCoordinator.shared.accountStateChanged()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRelayCoordinator.shared.received(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Local alerts and foreground sync remain available.
    }

    private func scheduleMailRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.mailRefreshIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.mailRefreshIdentifier)
        // iOS chooses the actual execution time based on usage, power, and network.
        // Fifteen minutes is the earliest request, not a guaranteed interval.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleMailRefresh(_ task: BGAppRefreshTask) {
        scheduleMailRefresh()
        guard let store = Self.store else {
            task.setTaskCompleted(success: false)
            return
        }

        let operation = Task { @MainActor [weak self] in
            await store.sync()
            guard !Task.isCancelled else { return }
            task.setTaskCompleted(success: true)
            self?.backgroundSyncTask = nil
        }
        backgroundSyncTask = operation
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.backgroundSyncTask?.cancel()
                self?.backgroundSyncTask = nil
                task.setTaskCompleted(success: false)
            }
        }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            guard let store = Self.store else { completionHandler(.noData); return }
            let before = store.messages.count
            await store.sync()
            completionHandler(store.messages.count == before ? .noData : .newData)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}
