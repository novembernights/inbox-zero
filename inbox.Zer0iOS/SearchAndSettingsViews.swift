import SwiftUI

struct MailSearchView: View {
    @Bindable var store: InboxStore
    @AppStorage("inboxZeroMonochrome") private var monochrome = false
    @State private var query = ""
    @State private var result: SearchAnswer?
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    @State private var speech = SpeechTranscriber()
    @State private var voiceError: String?
    @State private var didSearch = false
    @State private var searchRequestID = UUID()
    @State private var lastSubmittedQuery = ""

    var body: some View {
        Group {
            if hasSearchState {
                resultsRegion
            } else {
                emptySearchRegion
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Done") {
                    searchFocused = false
                }
                .font(InboxDesign.Typography.font(.body, weight: .semibold))
                .accessibilityHint("Dismisses the keyboard without searching")

                Spacer()
            }
        }
        .onChange(of: speech.transcript) { _, transcript in query = transcript }
        .onChange(of: searchFocused) { _, focused in
            if focused && speech.isRecording { speech.stop() }
        }
        .task {
            store.prepareSearchIntelligence()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-MockRecording") {
                speech.isRecording = true
            }
            if ProcessInfo.processInfo.arguments.contains("-MockAskResults") {
                result = SearchAnswer(
                    answer: "Your latest messages are ready. Open a source below to review the full email.",
                    sources: []
                )
                lastSubmittedQuery = "Recent emails"
                didSearch = true
            }
            if ProcessInfo.processInfo.arguments.contains("-FocusAsk") {
                try? await Task.sleep(for: .milliseconds(450))
                searchFocused = true
            }
#endif
        }
        .onDisappear {
            speech.stop()
        }
        .animation(.snappy(duration: 0.24), value: searchFocused)
        .animation(.snappy(duration: 0.32), value: hasSearchState)
    }

    private var emptySearchRegion: some View {
        ScrollView {
            VStack {
                Spacer(minLength: 0)

                if !searchFocused {
                    voiceSurface
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            questionField
                .padding(.horizontal, InboxDesign.Spacing.large)
                .padding(.bottom, composerBottomPadding)
        }
    }

    private var resultsRegion: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InboxDesign.Spacing.xLarge) {
                if let voiceError { Text(voiceError).font(InboxDesign.Typography.font(.caption)).foregroundStyle(.red) }

                if let result {
                    VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
                        LucideLabel(title: "Answer", icon: "astroid", iconSize: 16)
                            .font(InboxDesign.Typography.font(.caption, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(result.answer)
                            .font(InboxDesign.Typography.font(.body, weight: .medium))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(InboxDesign.Spacing.large)
                    .inboxContentSurface(
                        radius: InboxDesign.Radius.feature,
                        level: .elevated300,
                        emphasized: true
                    )

                    VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
                        HStack {
                            Text("Sources").font(InboxDesign.Typography.font(.headline, weight: .semibold))
                            Spacer()
                            Text(result.sources.count, format: .number)
                                .font(InboxDesign.Typography.font(.caption, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(result.sources) { message in
                                NavigationLink {
                                    LibraryMessageView(store: store, message: message)
                                        .onAppear { store.recordSearchSelection(query: lastSubmittedQuery, message: message) }
                                } label: {
                                    HStack(spacing: InboxDesign.Spacing.medium) {
                                        SenderMark(message: message, size: 42)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(message.senderName).font(InboxDesign.Typography.font(.headline, weight: .semibold))
                                            Text(message.subject).font(InboxDesign.Typography.font(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
                                            Text(message.participatesInWorkflow == false ? "Historical email" : message.queue.rawValue)
                                                .font(InboxDesign.Typography.font(.caption2, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: InboxDesign.Spacing.small)
                                        VStack(alignment: .trailing, spacing: InboxDesign.Spacing.small) {
                                            Text(message.receivedAt, style: .date).font(InboxDesign.Typography.font(.caption)).foregroundStyle(.secondary)
                                            LucideIcon(name: "chevron-right", size: 13).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                    .padding(.vertical, InboxDesign.Spacing.medium)
                                }
                                .buttonStyle(.plain)
                                if message.id != result.sources.last?.id {
                                    Divider().padding(.leading, 55)
                                }
                            }
                        }
                    }
                    .padding(InboxDesign.Spacing.large)
                    .inboxContentSurface(radius: InboxDesign.Radius.feature)
                } else if didSearch && !isSearching {
                    ContentUnavailableView.search(text: lastSubmittedQuery)
                }
            }
            .padding(.horizontal, InboxDesign.Spacing.large)
            .padding(.top, InboxDesign.Spacing.large)
            .padding(.bottom, InboxDesign.Spacing.xLarge)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            followUpComposer
                .padding(.horizontal, InboxDesign.Spacing.large)
                .padding(.top, InboxDesign.Spacing.small)
                .padding(.bottom, composerBottomPadding)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The iOS 26 liquid-glass tab bar visually floats above the content safe
    /// area. Keep the resting composer clear of it; once the keyboard is open,
    /// SwiftUI's keyboard safe area supplies the required lift instead.
    private var composerBottomPadding: CGFloat {
        searchFocused ? InboxDesign.Spacing.medium : InboxDesign.floatingTabBarClearance
    }

    private var voiceSurface: some View {
        VStack {
            Button {
                Task { await toggleVoiceSearch() }
            } label: {
                AskLiquidOrbControl(
                    isRecording: speech.isRecording,
                    isStarting: speech.isStarting
                )
            }
            .buttonStyle(AuraOrbButtonStyle())
            .disabled(speech.isStarting)
            .accessibilityLabel(speech.isRecording ? "Finish voice question" : "Ask by voice")
            .accessibilityHint(speech.isRecording ? "Stops listening and searches the transcript" : "Dictate a question about your email")
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.28), value: speech.isRecording)
    }

    private var questionField: some View {
        HStack(spacing: InboxDesign.Spacing.small) {
            TextField("Or type a question", text: $query, axis: .vertical)
                .font(InboxDesign.Typography.font(.body, weight: .medium))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { submitEditedQuery() }

            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
            } else if hasQuery {
                Button(action: submitEditedQuery) {
                    LucideIcon(name: "arrow-up", size: 18)
                        .foregroundStyle(Color.white)
                        .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
                        .background(searchAccent, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Search")
                .accessibilityHint("Searches your mailboxes using the edited question")
            }

            if result != nil || didSearch {
                Button(action: clearSearch) {
                    LucideIcon(name: "circle-x", size: 19)
                        .foregroundStyle(.secondary)
                        .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityHint("Clears the question, answer, and sources")
            }
        }
        .frame(minHeight: 54)
    }

    private var followUpComposer: some View {
        HStack(spacing: InboxDesign.Spacing.small) {
            TextField("Ask a follow-up", text: $query, axis: .vertical)
                .font(InboxDesign.Typography.font(.body, weight: .medium))
                .textFieldStyle(.plain)
                .lineLimit(1...2)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { submitEditedQuery() }

            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
            } else if hasQuery {
                Button(action: submitEditedQuery) {
                    LucideIcon(name: "arrow-up", size: 18)
                        .foregroundStyle(Color.white)
                        .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
                        .background(searchAccent, in: Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Search follow-up")
            } else {
                Button {
                    Task { await toggleVoiceSearch() }
                } label: {
                    LucideIcon(name: "audio-lines", size: 19)
                        .foregroundStyle(searchAccent)
                        .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(speech.isStarting)
                .accessibilityLabel(speech.isRecording ? "Finish voice follow-up" : "Ask a voice follow-up")
            }

            Button(action: clearSearch) {
                LucideIcon(name: "circle-x", size: 19)
                    .foregroundStyle(.secondary)
                    .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
        }
        .frame(minHeight: 54)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 0.5)
        }
    }

    private var searchAccent: Color {
        monochrome ? .primary : .blue
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSearchState: Bool {
        didSearch || result != nil || isSearching
    }

    private func submitEditedQuery() {
        guard hasQuery, !isSearching else { return }
        let wasRecording = speech.isRecording
        if wasRecording { speech.stop() }
        search(playSounds: !wasRecording)
    }

    private func search(playSounds: Bool = true) {
        guard hasQuery else { return }
        let submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSubmittedQuery = submittedQuery
        searchFocused = false
        InteractionFeedback.shared.perform(.beginWork, sound: playSounds)
        isSearching = true
        didSearch = true
        result = nil
        let requestID = UUID()
        searchRequestID = requestID
        Task {
            let answer = await store.search(submittedQuery)
            guard searchRequestID == requestID else { return }
            result = answer
            isSearching = false
            query = ""
            speech.transcript = ""
            InteractionFeedback.shared.perform(answer == nil ? .error : .ready, sound: playSounds)
        }
    }

    private func clearSearch() {
        searchRequestID = UUID()
        if speech.isRecording { speech.stop() }
        speech.transcript = ""
        query = ""
        lastSubmittedQuery = ""
        result = nil
        voiceError = nil
        didSearch = false
        isSearching = false
        searchFocused = true
    }

    private func toggleVoiceSearch() async {
        guard !speech.isStarting else { return }
        searchFocused = false
        voiceError = nil
        if speech.isRecording {
            speech.stop()
            InteractionFeedback.shared.perform(.ready, sound: false)
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search(playSounds: false) }
        } else {
            InteractionFeedback.shared.perform(.beginWork, sound: false)
            do { try await speech.start() }
            catch {
                voiceError = error.localizedDescription
                InteractionFeedback.shared.perform(.error, sound: false)
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var store: InboxStore
    @AppStorage("inboxZeroMonochrome") private var monochrome = false
    @AppStorage("inboxZeroAtmosphereStyle") private var atmosphereStyle = "blue"
    @AppStorage(InteractionFeedback.soundsKey) private var interactionSounds = true
    @AppStorage(InteractionFeedback.hapticsKey) private var haptics = true
    @State private var showingDebugGmailSetup = ProcessInfo.processInfo.arguments.contains("-OpenGmailSetup")
    @State private var showingDebugICloudSetup = ProcessInfo.processInfo.arguments.contains("-OpenICloudSetup")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
                Text("Settings")
                    .font(InboxDesign.Typography.screenTitle)

                SettingsOverviewCard("Connections", emphasized: true) {
                    NavigationLink {
                        EmailAccountsSettingsView(store: store)
                    } label: {
                        SettingsNavigationRow(
                            icon: "mail",
                            title: "Email accounts",
                            detail: emailSummary,
                            tint: monochrome ? .primary : .blue
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()

                    NavigationLink {
                        CalendarSettingsView(context: store.dailyContext)
                    } label: {
                        SettingsNavigationRow(
                            icon: "blocks",
                            title: "Calendar",
                            detail: productivitySummary,
                            tint: monochrome ? .primary : .purple
                        )
                    }
                    .buttonStyle(.plain)
                }

                SettingsOverviewCard("Preferences") {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsNavigationRow(
                            icon: "palette",
                            title: "Appearance",
                            detail: appearanceSummary,
                            tint: monochrome ? .primary : .blue
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()

                    NavigationLink {
                        InteractionSettingsView()
                    } label: {
                        SettingsNavigationRow(
                            icon: "audio-lines",
                            title: "Sounds & haptics",
                            detail: feedbackSummary,
                            tint: monochrome ? .primary : .orange
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()

                    NavigationLink {
                        WorkflowSettingsView(store: store)
                    } label: {
                        SettingsNavigationRow(
                            icon: "layers",
                            title: "Workflow",
                            detail: workflowSummary,
                            tint: monochrome ? .primary : .green
                        )
                    }
                    .buttonStyle(.plain)
                }

                SettingsOverviewCard("Privacy & About") {
                    SettingsInfoRow(
                        icon: "astroid",
                        title: "On-device & private",
                        detail: "Intelligence \(store.intelligence.status.title.lowercased()) · Email stays on this device",
                        tint: monochrome ? .primary : .blue
                    )

                    Divider()

                    SettingsInfoRow(
                        icon: "info",
                        title: "inbox.Zerø",
                        detail: "Version 1.0",
                        tint: .secondary
                    )
                }
            }
            .padding(.horizontal, InboxDesign.Spacing.large)
            .padding(.top, InboxDesign.Spacing.medium)
            .padding(.bottom, 110)
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert("inbox.Zerø", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("Daily Briefing", isPresented: Binding(
            get: { store.dailyContext.errorMessage != nil },
            set: { if !$0 { store.dailyContext.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.dailyContext.errorMessage = nil }
        } message: {
            Text(store.dailyContext.errorMessage ?? "")
        }
        .sheet(isPresented: $showingDebugGmailSetup) {
            GmailOAuthSetupView(store: store)
        }
        .sheet(isPresented: $showingDebugICloudSetup) {
            ICloudMailSetupView(store: store)
        }
    }

    private var emailSummary: String {
        switch store.accountEmails.count {
        case 0: "Not connected"
        case 1: "1 mailbox connected"
        default: "\(store.accountEmails.count) mailboxes connected"
        }
    }

    private var productivitySummary: String {
        store.dailyContext.calendarConnected ? "Connected" : "Not connected"
    }

    private var appearanceSummary: String {
        monochrome ? "Monochrome" : "Color · \(atmosphereTitle)"
    }

    private var feedbackSummary: String {
        switch (interactionSounds, haptics) {
        case (true, true): "Sounds and haptics on"
        case (true, false): "Sounds on"
        case (false, true): "Haptics on"
        case (false, false): "Off"
        }
    }

    private var workflowSummary: String {
        let total = InboxQueue.allCases.reduce(0) { $0 + store.count(in: $1) }
        return total == 1 ? "1 active message" : "\(total) active messages"
    }

    private var atmosphereTitle: String {
        switch atmosphereStyle {
        case "off": "Off"
        case "pearl": "Pearl"
        case "slateHaze": "Slate Haze"
        default: "Blue"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let emphasized: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, emphasized: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.emphasized = emphasized
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
            Text(title)
                .font(InboxDesign.Typography.section)
                .foregroundStyle(.secondary)
                .padding(.horizontal, InboxDesign.Spacing.small)

            VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
                content()
            }
            .padding(.horizontal, InboxDesign.Spacing.large)
            .padding(.vertical, InboxDesign.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inboxContentSurface(
                radius: InboxDesign.Radius.feature,
                level: emphasized ? .elevated300 : .raised200,
                emphasized: emphasized
            )
        }
    }
}

private struct SettingsOverviewCard<Content: View>: View {
    let title: String
    let emphasized: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, emphasized: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.emphasized = emphasized
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
            Text(title)
                .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.7)

            content()
        }
        .padding(.horizontal, InboxDesign.Spacing.large)
        .padding(.vertical, InboxDesign.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inboxContentSurface(
            radius: InboxDesign.Radius.feature,
            level: emphasized ? .elevated300 : .raised200,
            emphasized: emphasized
        )
    }
}

private struct SettingsNavigationRow: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: InboxDesign.Spacing.medium) {
            LucideIcon(name: icon, size: 21)
                .frame(width: 28, alignment: .center)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                Text(detail)
                    .font(InboxDesign.Typography.font(.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LucideIcon(name: "chevron-right", size: 15)
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SettingsInfoRow: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: InboxDesign.Spacing.medium) {
            LucideIcon(name: icon, size: 21)
                .frame(width: 28, alignment: .center)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                Text(detail)
                    .font(InboxDesign.Typography.font(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}

private struct EmailAccountsSettingsView: View {
    @Bindable var store: InboxStore
    @AppStorage("inboxZeroMonochrome") private var monochrome = false
    @State private var showingOAuthSetup = false
    @State private var showingICloudSetup = ProcessInfo.processInfo.arguments.contains("-OpenICloudSetup")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                SettingsCard("Connected accounts", emphasized: !store.accountEmails.isEmpty) {
                    if store.accountEmails.isEmpty {
                        SettingsInfoRow(
                            icon: "mail-x",
                            title: "No mailboxes yet",
                            detail: "Connect Gmail or iCloud Mail below.",
                            tint: .secondary
                        )
                    } else {
                        ForEach(Array(store.accountEmails.enumerated()), id: \.element) { index, email in
                            if index > 0 { Divider() }
                            accountRow(email: email, index: index)
                        }
                    }
                }

                SettingsCard("Add account", emphasized: store.accountEmails.isEmpty) {
                    gmailConnectControl

                    Divider()

                    Button { showingICloudSetup = true } label: {
                        SettingsNavigationRow(
                            icon: "cloud",
                            title: "iCloud Mail",
                            detail: "Use an Apple app-specific password",
                            tint: monochrome ? .primary : .blue
                        )
                    }
                    .buttonStyle(.plain)
                }

                SettingsCard("Mailbox actions") {
                    Button { Task { await store.sync() } } label: {
                        SettingsActionRow(
                            icon: "refresh-cw",
                            title: store.isSyncing ? "Syncing…" : "Sync now",
                            tint: .primary
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(store.isSyncing)

                    if !store.gmail.storedAccountEmails.isEmpty {
                        Divider()
                        Button(role: .destructive) { store.signOut() } label: {
                            SettingsActionRow(
                                icon: "unlink",
                                title: "Disconnect all Gmail accounts",
                                tint: .red
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }

                    if !store.iCloud.storedAccountEmails.isEmpty {
                        Divider()
                        Menu {
                            ForEach(store.iCloud.storedAccountEmails, id: \.self) { email in
                                Button("Disconnect \(email)", role: .destructive) {
                                    store.disconnectICloud(email: email)
                                }
                            }
                        } label: {
                            SettingsActionRow(
                                icon: "unlink",
                                title: "Disconnect iCloud Mail",
                                tint: .red,
                                showsMenuIndicator: true
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, InboxDesign.Spacing.large)
            .padding(.vertical, InboxDesign.Spacing.medium)
            .padding(.bottom, InboxDesign.Spacing.xLarge)
        }
        .background(AtmosphereBackground())
        .navigationTitle("Email accounts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $showingOAuthSetup) { GmailOAuthSetupView(store: store) }
        .sheet(isPresented: $showingICloudSetup) { ICloudMailSetupView(store: store) }
    }

    @ViewBuilder
    private var gmailConnectControl: some View {
        if store.accountEmails.isEmpty {
            Button {
                if store.gmail.isConfigured {
                    Task { await store.signIn() }
                } else {
                    showingOAuthSetup = true
                }
            } label: {
                SettingsNavigationRow(
                    icon: "mail-plus",
                    title: store.gmail.isConfigured ? "Gmail" : "Set up Gmail",
                    detail: store.gmail.isConfigured ? "Continue securely with Google" : "Configure OAuth, then sign in",
                    tint: monochrome ? .primary : .red
                )
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if store.gmail.isConfigured {
                    Task { await store.signIn() }
                } else {
                    showingOAuthSetup = true
                }
            } label: {
                SettingsNavigationRow(
                    icon: "mail-plus",
                    title: "Gmail",
                    detail: "Add another Google mailbox",
                    tint: monochrome ? .primary : .red
                )
            }
        }
    }

    private func accountRow(email: String, index: Int) -> some View {
        HStack(spacing: InboxDesign.Spacing.medium) {
            LucideIcon(name: "mail-check", size: 22)
                .frame(width: 28)
                .foregroundStyle(monochrome ? Color.primary : MailboxPersona.color(for: email))

            VStack(alignment: .leading, spacing: 3) {
                TextField(
                    "Mailbox name",
                    text: Binding(
                        get: { MailboxPersona.name(for: email) },
                        set: { UserDefaults.standard.set($0, forKey: MailboxPersona.nameKey(for: email)) }
                    )
                )
                .font(InboxDesign.Typography.font(.headline, weight: .semibold))

                Text("\(email) · \(store.provider(forAccount: email).displayName) \(syncStatus(for: email))")
                    .font(InboxDesign.Typography.font(.caption))
                    .foregroundStyle(accountError(for: email) == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Circle()
                .strokeBorder(monochrome ? Color.primary.opacity(0.55) : MailboxPersona.color(for: email), lineWidth: 2.5)
                .frame(width: 18, height: 18)
        }
        .frame(minHeight: 58)
    }

    private func syncStatus(for email: String) -> String {
        if accountError(for: email) != nil { return "· Reconnect" }
        guard let lastSyncAt = store.lastSyncAt else { return "· Connected" }
        return "· Updated \(lastSyncAt.formatted(.relative(presentation: .named)))"
    }

    private func accountError(for email: String) -> String? {
        switch store.provider(forAccount: email) {
        case .gmail: store.gmail.accountSyncErrors[email]
        case .iCloud: store.iCloud.accountSyncErrors[email]
        }
    }
}

private struct SettingsActionRow: View {
    let icon: String
    let title: String
    let tint: Color
    var showsMenuIndicator = false

    var body: some View {
        HStack(spacing: InboxDesign.Spacing.medium) {
            LucideIcon(name: icon, size: 20)
                .frame(width: 28)
                .foregroundStyle(tint)
            Text(title)
                .font(InboxDesign.Typography.font(.body, weight: .medium))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            if showsMenuIndicator {
                LucideIcon(name: "chevron-down", size: 14)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct CalendarSettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let context: DailyContextService
    @AppStorage("inboxZeroMonochrome") private var monochrome = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                SettingsCard("Daily briefing", emphasized: true) {
                    integrationRow(
                        icon: "calendar-days",
                        title: "Calendar",
                        detail: context.calendarConnected
                            ? "\(context.calendarEventCount) events remaining today"
                            : "Include today’s calendar events",
                        tint: monochrome ? .primary : .red,
                        connected: context.calendarConnected,
                        connect: { Task { await context.requestCalendarAccess() } }
                    )

                    if context.isRefreshing {
                        Divider()
                        ProgressView("Refreshing briefing…")
                            .font(InboxDesign.Typography.font(.caption))
                    }
                }
            }
            .padding(.horizontal, InboxDesign.Spacing.large)
            .padding(.vertical, InboxDesign.Spacing.medium)
        }
        .background(AtmosphereBackground())
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    @ViewBuilder
    private func integrationRow(
        icon: String,
        title: String,
        detail: String,
        tint: Color,
        connected: Bool,
        connect: @escaping () -> Void
    ) -> some View {
        let content = HStack(spacing: InboxDesign.Spacing.medium) {
            LucideIcon(name: icon, size: 22)
                .frame(width: 28)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(InboxDesign.Typography.font(.headline, weight: .semibold))
                Text(detail).font(InboxDesign.Typography.font(.caption)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
                content
                integrationControl(title: title, connected: connected, connect: connect)
            }
        } else {
            HStack(spacing: InboxDesign.Spacing.medium) {
                content
                integrationControl(title: title, connected: connected, connect: connect)
            }
        }
    }

    @ViewBuilder
    private func integrationControl(title: String, connected: Bool, connect: @escaping () -> Void) -> some View {
        if connected {
            LucideLabel(title: "Connected", icon: "circle-check", iconSize: 16)
                .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                .foregroundStyle(.green)
                .frame(minHeight: InboxDesign.minimumTouchTarget)
        } else {
            Button("Connect", action: connect)
                .buttonStyle(.bordered)
        }
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("inboxZeroMonochrome") private var monochrome = false
    @AppStorage("inboxZeroAtmosphereStyle") private var atmosphereStyle = "blue"

    var body: some View {
        SettingsDetailPage(title: "Appearance") {
            SettingsCard("Display", emphasized: true) {
                HStack(spacing: InboxDesign.Spacing.medium) {
                    LucideIcon(name: "palette", size: 21).frame(width: 28)
                    Toggle("Monochrome appearance", isOn: $monochrome)
                        .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                }

                Divider()

                HStack(spacing: InboxDesign.Spacing.medium) {
                    LucideIcon(name: "cloud-sun", size: 21)
                        .frame(width: 28)
                        .foregroundStyle(atmosphereStyle == "blue" && !monochrome ? Color.blue : Color.secondary)
                    Text("Background atmosphere")
                        .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                    Spacer()
                    Picker("Background atmosphere", selection: $atmosphereStyle) {
                        Text("Off").tag("off")
                        Text("Blue").tag("blue")
                        Text("Pearl").tag("pearl")
                        Text("Slate Haze").tag("slateHaze")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(monochrome)
                }
                .frame(minHeight: 52)
            }
        }
    }
}

private struct InteractionSettingsView: View {
    @AppStorage(InteractionFeedback.soundsKey) private var interactionSounds = true
    @AppStorage(InteractionFeedback.hapticsKey) private var haptics = true

    var body: some View {
        SettingsDetailPage(title: "Sounds & haptics") {
            SettingsCard("Feedback", emphasized: true) {
                HStack(spacing: InboxDesign.Spacing.medium) {
                    LucideIcon(name: "audio-lines", size: 21).frame(width: 28)
                    Toggle("Interaction sounds", isOn: $interactionSounds)
                        .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                }

                Divider()

                HStack(spacing: InboxDesign.Spacing.medium) {
                    LucideIcon(name: "vibrate", size: 21).frame(width: 28)
                    Toggle("Haptic feedback", isOn: $haptics)
                        .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                }
            }
        }
    }
}

private struct WorkflowSettingsView: View {
    @Bindable var store: InboxStore
    @AppStorage("inboxZeroMonochrome") private var monochrome = false

    var body: some View {
        SettingsDetailPage(title: "Workflow") {
            SettingsCard("Queue overview", emphasized: true) {
                Text("Messages remain under your control across the four action states.")
                    .font(InboxDesign.Typography.font(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(InboxQueue.allCases) { queue in
                    Divider()
                    HStack(spacing: InboxDesign.Spacing.medium) {
                        LucideIcon(name: queue.icon, size: 18)
                            .frame(width: 28)
                            .foregroundStyle(monochrome ? Color.secondary : queue.color)
                        Text(queue.rawValue)
                            .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                        Spacer()
                        Text(store.count(in: queue), format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }
}

private struct SettingsDetailPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                content()
            }
            .padding(.horizontal, InboxDesign.Spacing.large)
            .padding(.vertical, InboxDesign.Spacing.medium)
        }
        .background(AtmosphereBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

private struct ConnectionSetupHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
                    iconView
                    copy
                }
            } else {
                HStack(alignment: .top, spacing: InboxDesign.Spacing.medium) {
                    iconView
                    copy.padding(.top, 2)
                }
            }
        }
    }

    private var iconView: some View {
        LucideIcon(name: icon, size: 24)
            .frame(width: 48, height: 48)
            .background(.thinMaterial, in: Circle())
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.xSmall) {
            Text(title)
                .font(InboxDesign.Typography.screenTitle)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(InboxDesign.Typography.screenSubtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConnectionSetupField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
            Text(label)
                .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            content()
                .font(InboxDesign.Typography.font(.body, weight: .medium))
                .padding(.horizontal, InboxDesign.Spacing.medium)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(
                    InboxDesign.SurfaceLevel.background100.color,
                    in: RoundedRectangle(cornerRadius: InboxDesign.Radius.control, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: InboxDesign.Radius.control, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                }
        }
    }
}

private struct ConnectionPrimaryAction: View {
    let title: String
    let loadingTitle: String
    let isLoading: Bool
    let isEnabled: Bool
    let accessibilityHint: String
    let action: () -> Void

    private var active: Bool { isEnabled || isLoading }

    var body: some View {
        Button(action: action) {
            HStack(spacing: InboxDesign.Spacing.small) {
                if isLoading { ProgressView().tint(.white) }
                LucideLabel(
                    title: isLoading ? loadingTitle : title,
                    icon: "arrow-right",
                    iconSize: 19
                )
            }
            .font(InboxDesign.Typography.font(.headline, weight: .semibold))
            .foregroundStyle(active ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                active ? Color.primary : InboxDesign.SurfaceLevel.raised200.color,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(active ? 0 : 0.08), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .accessibilityHint(accessibilityHint)
    }
}

private struct ConnectionErrorMessage: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: InboxDesign.Spacing.small) {
            LucideIcon(name: "triangle-alert", size: 17)
            Text(message)
        }
        .font(InboxDesign.Typography.font(.caption, weight: .medium))
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ICloudMailSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: InboxStore
    @State private var email = ""
    @State private var appSpecificPassword = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email
        case password
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                    ConnectionSetupHeader(
                        icon: "cloud",
                        title: "Connect iCloud Mail",
                        subtitle: "Add your Apple mailbox to inbox.Zerø."
                    )

                    SettingsCard("Apple Account") {
                        VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
                            Text("Use an app-specific password for inbox.Zerø—not your normal Apple Account password.")
                                .font(InboxDesign.Typography.font(.subheadline))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider()

                            Link(destination: URL(string: "https://account.apple.com/account/manage")!) {
                                HStack(spacing: InboxDesign.Spacing.medium) {
                                    LucideIcon(name: "external-link", size: 19)
                                        .frame(width: 28)
                                    Text("Open Apple Account")
                                        .font(InboxDesign.Typography.font(.body, weight: .medium))
                                    Spacer(minLength: 0)
                                    LucideIcon(name: "chevron-right", size: 15)
                                        .foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }

                    SettingsCard("Account details", emphasized: true) {
                        VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                            ConnectionSetupField("iCloud email") {
                                TextField("you@icloud.com", text: $email)
                                    .textContentType(.emailAddress)
                                    .keyboardType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .focused($focusedField, equals: .email)
                                    .onSubmit { focusedField = .password }
                            }

                            ConnectionSetupField("App-specific password") {
                                SecureField("xxxx-xxxx-xxxx-xxxx", text: $appSpecificPassword)
                                    .textContentType(.password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.body.monospaced())
                                    .submitLabel(.go)
                                    .focused($focusedField, equals: .password)
                                    .onSubmit { if canConnect { connect() } }
                            }

                            Divider()

                            LucideLabel(title: "Saved only in this device’s Keychain", icon: "shield-check", iconSize: 17)
                                .font(InboxDesign.Typography.font(.caption, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        ConnectionErrorMessage(message: errorMessage)
                    }
                }
                .padding(.horizontal, InboxDesign.Spacing.large)
                .padding(.top, InboxDesign.Spacing.medium)
                .padding(.bottom, InboxDesign.Spacing.xLarge)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .background(AtmosphereBackground())
            .navigationTitle("iCloud Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ConnectionPrimaryAction(
                    title: "Connect iCloud Mail",
                    loadingTitle: "Connecting…",
                    isLoading: isConnecting,
                    isEnabled: canConnect,
                    accessibilityHint: "Connects this mailbox using the app-specific password",
                    action: connect
                )
                    .padding(.horizontal, InboxDesign.Spacing.large)
                    .padding(.top, InboxDesign.Spacing.small)
                    .padding(.bottom, InboxDesign.Spacing.medium)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private var canConnect: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appSpecificPassword.isEmpty
            && !isConnecting
    }

    private func connect() {
        focusedField = nil
        errorMessage = nil
        isConnecting = true
        Task {
            do {
                try await store.connectICloud(email: email, appSpecificPassword: appSpecificPassword)
                appSpecificPassword = ""
                isConnecting = false
                dismiss()
            } catch {
                appSpecificPassword = ""
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }
}

private struct GmailOAuthSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: InboxStore
    @State private var clientID = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var clientIDFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                    ConnectionSetupHeader(
                        icon: "mail-plus",
                        title: "Connect Gmail",
                        subtitle: "Add your Google mailbox to inbox.Zerø."
                    )

                    SettingsCard("Google Cloud") {
                        VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
                            Text("Create an iOS OAuth client for inbox.Zerø. Google handles sign-in, so your Google password is never shared with the app.")
                                .font(InboxDesign.Typography.font(.subheadline))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider()

                            Link(destination: URL(string: "https://console.cloud.google.com/apis/credentials")!) {
                                HStack(spacing: InboxDesign.Spacing.medium) {
                                    LucideIcon(name: "external-link", size: 19)
                                        .frame(width: 28)
                                    Text("Open Google Cloud")
                                        .font(InboxDesign.Typography.font(.body, weight: .medium))
                                    Spacer(minLength: 0)
                                    LucideIcon(name: "chevron-right", size: 15)
                                        .foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }

                    SettingsCard("OAuth client", emphasized: true) {
                        VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                            ConnectionSetupField("Client ID") {
                                TextField("123…apps.googleusercontent.com", text: $clientID, axis: .vertical)
                                    .textContentType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.body.monospaced())
                                    .lineLimit(1...3)
                                    .submitLabel(.go)
                                    .focused($clientIDFocused)
                                    .onSubmit { if canConnect { connect() } }
                            }

                            Text("Bundle ID: \(Bundle.main.bundleIdentifier ?? "Not configured")")
                                .font(InboxDesign.Typography.font(.caption, weight: .medium))
                                .foregroundStyle(.secondary)

                            Divider()

                            LucideLabel(title: "Google sign-in uses OAuth 2.0 with PKCE", icon: "shield-check", iconSize: 17)
                                .font(InboxDesign.Typography.font(.caption, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        ConnectionErrorMessage(message: errorMessage)
                    }
                }
                .padding(.horizontal, InboxDesign.Spacing.large)
                .padding(.top, InboxDesign.Spacing.medium)
                .padding(.bottom, InboxDesign.Spacing.xLarge)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .background(AtmosphereBackground())
            .navigationTitle("Gmail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ConnectionPrimaryAction(
                    title: "Continue with Google",
                    loadingTitle: "Connecting…",
                    isLoading: isConnecting,
                    isEnabled: canConnect,
                    accessibilityHint: "Saves the OAuth client ID and opens Google sign-in",
                    action: connect
                )
                    .padding(.horizontal, InboxDesign.Spacing.large)
                    .padding(.top, InboxDesign.Spacing.small)
                    .padding(.bottom, InboxDesign.Spacing.medium)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private var canConnect: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isConnecting
    }

    private func connect() {
        clientIDFocused = false
        errorMessage = nil
        do {
            try store.gmail.configureOAuth(clientID: clientID)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isConnecting = true
        Task {
            await store.signIn()
            isConnecting = false
            if store.accountEmail != nil {
                dismiss()
            } else {
                errorMessage = store.errorMessage ?? "Google sign-in was not completed."
                store.errorMessage = nil
            }
        }
    }
}
