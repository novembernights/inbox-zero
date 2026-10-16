import SwiftUI

@main
struct InboxZeroIOSApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @State private var store = InboxStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(\.font, InboxDesign.Typography.body)
                .onAppear {
                    MobileAppDelegate.store = store
                    PushRelayCoordinator.shared.accountStateChanged()
                }
        }
    }
}

private struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: InboxStore
    @State private var selection: AppSection = Self.initialSection

    private static var initialSection: AppSection {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-OpenSettings") { return .settings }
        if arguments.contains("-OpenCompose") || arguments.contains("-OpenAllMailMenu") { return .mail }
        if arguments.contains("-OpenAllMail") { return .mail }
        if arguments.contains("-OpenAsk") { return .search }
        return .home
    }

    var body: some View {
        ZStack {
            AtmosphereBackground()

            TabView(selection: $selection) {
                NavigationStack {
                    DashboardView(store: store)
                }
                .tabItem { LucideLabel(title: "Home", icon: "house") }
                .tag(AppSection.home)

                NavigationStack {
                    MailSearchView(store: store)
                }
                .tabItem { LucideLabel(title: "Ask", icon: "astroid") }
                .tag(AppSection.search)

                NavigationStack {
                    AllMailLibraryView(store: store)
                }
                .tabItem { LucideLabel(title: "All Mail", icon: "inbox") }
                .tag(AppSection.mail)

                NavigationStack {
                    SettingsView(store: store)
                }
                .tabItem { LucideLabel(title: "Settings", icon: "settings") }
                .tag(AppSection.settings)
            }
            .tint(.primary)
            .onChange(of: selection) { _, _ in
                InteractionFeedback.shared.perform(.selection)
            }
        }
        .task {
            await store.start()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-MockUIData") {
                store.messages = InboxStore.previewMessages
                if ProcessInfo.processInfo.arguments.contains("-OpenCompose") {
                    store.accountEmails = ["alex@example.com", "team@example.org"]
                    store.accountEmail = "alex@example.com"
                }
            } else if ProcessInfo.processInfo.arguments.contains("-MockZeroMoment") {
                store.messages = InboxStore.previewMessages.map { message in
                    var completed = message
                    if completed.participatesInWorkflow != false { completed.queue = .done }
                    return completed
                }
            }
#endif
            if ProcessInfo.processInfo.arguments.contains("-StartGmailOAuth") {
                await store.signIn()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            store.intelligence.refreshAvailability()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-MockUIData") ||
                ProcessInfo.processInfo.arguments.contains("-MockZeroMoment") { return }
#endif
            await store.sync()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                await store.sync()
            }
        }
    }
}

private enum AppSection: Int, CaseIterable, Hashable {
    case home, search, mail, settings

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Ask"
        case .mail: "All Mail"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .search: "astroid"
        case .mail: "inbox"
        case .settings: "settings"
        }
    }
}


private struct IntelligenceRequirementsView: View {
    let status: IntelligenceStatus

    var body: some View {
        VStack(spacing: 21) {
            LucideIcon(name: "astroid", size: 54)
                .foregroundStyle(.primary)
            Text("Apple Intelligence required")
                .font(InboxDesign.Typography.font(.largeTitle, weight: .bold))
                .multilineTextAlignment(.center)
            Text(status.guidance)
                .font(InboxDesign.Typography.font(.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(34)
    }
}
