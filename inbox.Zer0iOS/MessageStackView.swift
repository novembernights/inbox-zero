import SwiftUI
import UniformTypeIdentifiers
import WebKit
import QuickLook
import EventKit
import PassKit
import SwipeActions

struct MessageStackView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("inboxZeroMonochrome") private var monochrome = false
    @Bindable var store: InboxStore
    let queue: InboxQueue
    @State private var index = 0
    @State private var dragOffset: CGSize = .zero
    @State private var swipeContainerWidth: CGFloat = 390
    @State private var swipeAxis: SwipeAxis?
    @State private var crossedSwipeThreshold = false
    @State private var isMovingMessage = false
    @State private var messageOpacity = 1.0
    @State private var activeComposer: ComposeMode?
    @State private var showUndo = false
    @State private var presentation: QueuePresentation = .message
    @State private var contentMode: MessageContentMode = .summary
    @State private var showingDeleteConfirmation = false
    @State private var deleteError: String?
    @State private var emptyMessageIndex = 0
    @State private var readerActionsExpanded = ProcessInfo.processInfo.arguments.contains("-OpenReaderActions")

    init(store: InboxStore, queue: InboxQueue, initialMessageID: String? = nil) {
        self.store = store
        self.queue = queue
        let queueMessages = store.messages(in: queue)
        _index = State(initialValue: initialMessageID.flatMap { requestedID in
            queueMessages.firstIndex { $0.id == requestedID }
        } ?? 0)
        _presentation = State(initialValue: initialMessageID == nil ? .list : .message)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MockUIData"),
           ProcessInfo.processInfo.arguments.contains("-OpenSwipePreview") {
            _presentation = State(initialValue: .message)
        }
#endif
    }

    private var messages: [InboxMessage] { store.messages(in: queue) }
    private var current: InboxMessage? { messages.indices.contains(index) ? messages[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .list {
                emailList
            } else if let message = current {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        fixedHeader(message)
                        contentModePicker
                        messageContent(message)
                        if showUndo { undoBanner }
                    }
                    .opacity(messageOpacity)
                }
                .simultaneousGesture(horizontalActionGesture(message))
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { swipeContainerWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in
                                swipeContainerWidth = width
                            }
                    }
                }
                .accessibilityAction(named: "Move to Done") { move(message, to: .done) }
                .accessibilityAction(named: "Move to Read Later") { move(message, to: .readLater) }
                .accessibilityAction(named: "Move to Action") { move(message, to: .action) }
                .accessibilityAction(named: "Move to Waiting") { move(message, to: .waiting) }
                .accessibilityAction(named: "Next email") { showNext() }
                .accessibilityAction(named: "Previous email") { showPrevious() }
                .sheet(item: $activeComposer) { mode in
                    ReplyComposer(store: store, message: message, mode: mode)
                }
                .task(id: message.id) {
                    _ = await store.summary(for: message)
                }
            } else {
                emptyQueueView
            }
        }
        .navigationTitle(presentation == .message ? "Email" : queue.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: togglePresentation) {
                    HStack(spacing: InboxDesign.Spacing.xSmall) {
                        LucideIcon(
                            name: presentation == .list ? "mail" : "list",
                            size: 15
                        )
                        Text(presentation == .list ? "Message" : "Queue")
                            .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                    }
                }
                .disabled(presentation == .list && current == nil)
                .accessibilityHint(
                    presentation == .list
                        ? "Opens the current message"
                        : "Shows every message in this queue"
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if presentation == .message, let message = current {
                bottomActionRail(message)
                    .padding(.leading, InboxDesign.Spacing.large)
                    .padding(.trailing, 88)
                    .padding(.top, InboxDesign.Spacing.small)
                    .padding(.bottom, InboxDesign.Spacing.large)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if presentation == .message, let message = current {
                actionBar(message)
            }
        }
        .onChange(of: current?.id) { _, _ in
            dragOffset = .zero
            swipeAxis = nil
            crossedSwipeThreshold = false
        }
        .confirmationDialog(
            "Move this email to Trash?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Email", role: .destructive) {
                guard let message = current else { return }
                Task { await delete(message) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can recover it later from your mail provider’s Trash.")
        }
        .alert("Unable to Delete", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "Please try again.")
        }
        .task(id: messages.isEmpty) {
            guard messages.isEmpty, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.55)) {
                    emptyMessageIndex = (emptyMessageIndex + 1) % emptyQueueMessages.count
                }
            }
        }
    }

    private var emptyQueueView: some View {
        VStack(spacing: InboxDesign.Spacing.small) {
            EmptyQueueShimmerText("Touch Grass")

            Text(emptyQueueMessages[emptyMessageIndex % emptyQueueMessages.count])
                .font(InboxDesign.Typography.font(.subheadline))
                .foregroundStyle(.secondary.opacity(0.72))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .id(emptyMessageIndex)
        }
        .padding(.horizontal, InboxDesign.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Touch Grass. \(emptyQueueMessages[emptyMessageIndex % emptyQueueMessages.count])")
    }

    private var emptyQueueMessages: [String] {
        switch queue {
        case .action:
            [
                "Nothing needs you right now.",
                "Step outside. The inbox can wait.",
                "Take a breath and notice where you are.",
                "Be here for a little while."
            ]
        case .waiting:
            [
                "Nothing is waiting here.",
                "Let the rest unfold in its own time.",
                "Leave some room for the day to surprise you.",
                "Be present while the world catches up."
            ]
        case .readLater:
            [
                "Nothing is asking for later.",
                "Look up for a while.",
                "Make space for something offline.",
                "The moment in front of you is enough."
            ]
        case .done:
            [
                "A quiet inbox is its own reward.",
                "You made space. Enjoy it.",
                "Close the loop, then open the day.",
                "Nothing else is required right now."
            ]
        }
    }

    private var undoBanner: some View {
        Button {
            store.undoLastMove()
            showUndo = false
        } label: {
            HStack {
                Text("Message moved")
                Spacer()
                Text("Undo").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: InboxDesign.minimumTouchTarget)
            .padding(.horizontal, InboxDesign.Spacing.medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.regularMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel("Message moved. Undo")
    }

    private func togglePresentation() {
        InteractionFeedback.shared.perform(.selection, sound: false)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
            presentation = presentation == .list ? .message : .list
        }
    }

    private func bottomActionRail(_ message: InboxMessage) -> some View {
        let progress = min(abs(dragOffset.width) / swipeCommitThreshold, 1)
        return HStack(spacing: 28) {
            railAction(message, destination: .done, selected: dragOffset.width < 0, progress: progress)
            railAction(message, destination: .readLater, selected: dragOffset.width > 0, progress: progress)
        }
        .padding(5)
        .background(InboxDesign.SurfaceLevel.raised200.color, in: Capsule())
        .overlay {
            GeometryReader { geometry in
                LucideIcon(name: "grip-vertical", size: 15)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(InboxDesign.SurfaceLevel.elevated300.color, in: Circle())
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .offset(x: reduceMotion ? 0 : (dragOffset.width < 0 ? -1 : 1) * progress * geometry.size.width * 0.12)
                    .opacity(max(0, 1 - progress * 2.5))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .simultaneousGesture(horizontalActionGesture(message))
        .disabled(isMovingMessage)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Email actions")
    }

    private func railAction(_ message: InboxMessage, destination: InboxQueue, selected: Bool, progress: CGFloat) -> some View {
        let ready = selected && progress >= 1
        return Button {
            move(message, to: destination)
        } label: {
            LucideLabel(title: destination == .done ? "Done" : "Read Later", icon: destination.icon, iconSize: 16)
                .font(InboxDesign.Typography.font(.caption, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: InboxDesign.minimumTouchTarget)
                .foregroundStyle(ready ? Color(uiColor: .systemBackground) : Color.primary)
                .background(ready ? Color.primary : Color.clear, in: Capsule())
                .opacity(selected || progress == 0 ? 1 : 1 - progress * 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Move to \(destination.rawValue)")
        .accessibilityValue(ready ? "Release to move" : "")
    }

    private func fixedHeader(_ message: InboxMessage) -> some View {
        MessageReaderHeader(message: message)
    }

    private var contentModePicker: some View {
        EmailContentModePicker(selection: $contentMode)
    }

    @ViewBuilder
    private func messageContent(_ message: InboxMessage) -> some View {
        if contentMode == .fullEmail {
            VStack(spacing: 0) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    MessageFilesView(store: store, message: message, attachments: attachments)
                        .padding(.horizontal, InboxDesign.Spacing.large)
                        .padding(.top, InboxDesign.Spacing.medium)
                        .padding(.bottom, InboxDesign.Spacing.medium)
                }
                MailHTMLView(html: message.bodyHTML)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .accessibilityLabel("Full email from \(message.senderName)")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                if let invitation = message.attachments?.first(where: \.isCalendarInvitation) {
                    CalendarInvitationCard(store: store, message: message, attachment: invitation)
                } else if contentMode == .summary, let summary = message.displaySummary {
                    VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
                        LucideLabel(
                            title: message.summaryIsGenerated == true ? "AI Summary" : "Email Preview",
                            icon: message.summaryIsGenerated == true ? "astroid" : "align-left",
                            iconSize: 14
                        )
                            .font(InboxDesign.Typography.font(.caption, weight: .bold)).textCase(.uppercase).foregroundStyle(.secondary)
                        SummaryText(summary: summary)
                    }
                    .padding(InboxDesign.Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .inboxContentSurface()
                }

                if message.attachments?.contains(where: \.isCalendarInvitation) != true,
                   message.displaySummary == nil {
                    VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
                        LucideLabel(title: "Email Preview", icon: "align-left", iconSize: 14)
                            .font(InboxDesign.Typography.font(.caption, weight: .bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        SummaryText(summary: message.snippet)
                    }
                        .padding(InboxDesign.Spacing.large)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .inboxContentSurface()
                }
                }
                .padding(InboxDesign.Spacing.large)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emailList: some View {
        Group {
            if messages.isEmpty {
                emptyQueueView
            } else {
                ScrollView {
                    LazyVStack(spacing: InboxDesign.Spacing.medium) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { position, message in
                            Button {
                                index = position
                                contentMode = .summary
                                presentation = .message
                            } label: {
                                MailListCard(store: store, message: message)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                    .padding(.horizontal, InboxDesign.Spacing.large)
                    .padding(.vertical, InboxDesign.Spacing.medium)
                }
            }
        }
        .accessibilityLabel("All \(queue.rawValue) emails")
    }

    private func actionBar(_ message: InboxMessage) -> some View {
        MailContextActionMenu(
            context: .reader,
            isExpanded: $readerActionsExpanded,
            reply: { activeComposer = .reply },
            replyAll: { activeComposer = .replyAll },
            forward: { activeComposer = .forward },
            moveActions: InboxQueue.allCases.map { queue in
                MailContextMoveAction(
                    title: queue.rawValue,
                    icon: queue.icon,
                    action: { move(message, to: queue) }
                )
            } + [
                MailContextMoveAction(
                    title: "Delete Email",
                    icon: "trash-2",
                    role: .destructive,
                    action: { showingDeleteConfirmation = true }
                )
            ]
        )
        .padding(.trailing, InboxDesign.Spacing.large)
        .padding(.bottom, InboxDesign.Spacing.large)
    }

    private func horizontalActionGesture(_ message: InboxMessage) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard !isMovingMessage, !readerActionsExpanded else { return }
                if swipeAxis == nil {
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard max(horizontal, vertical) >= 10 else { return }
                    swipeAxis = horizontal > vertical * 1.2 ? .horizontal : .vertical
                }
                guard swipeAxis == .horizontal else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragOffset.width = value.translation.width
                }
                let crossed = abs(value.translation.width) >= swipeCommitThreshold
                if crossed && !crossedSwipeThreshold {
                    InteractionFeedback.shared.perform(.selection, sound: false)
                }
                crossedSwipeThreshold = crossed
            }
            .onEnded { value in
                defer {
                    swipeAxis = nil
                    crossedSwipeThreshold = false
                }
                guard !isMovingMessage, swipeAxis == .horizontal else { return }
                guard abs(value.translation.width) >= swipeCommitThreshold else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1)) {
                        dragOffset = .zero
                    }
                    return
                }
                move(message, to: value.translation.width < 0 ? .done : .readLater)
            }
    }

    private var swipeCommitThreshold: CGFloat {
        min(max(swipeContainerWidth * 0.30, 88), 132)
    }

    private func move(_ message: InboxMessage, to destination: InboxQueue) {
        guard !isMovingMessage else { return }
        guard message.queue != destination else {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1)) {
                dragOffset = .zero
            }
            return
        }
        isMovingMessage = true
        readerActionsExpanded = false
        InteractionFeedback.shared.perform(destination == .done ? .success : .page)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10), completionCriteria: .logicallyComplete) {
            messageOpacity = 0
        } completion: {
            store.move(message, to: destination)
            index = min(index, max(0, messages.count - 1))
            dragOffset = .zero
            showUndo = true
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.16), completionCriteria: .logicallyComplete) {
                messageOpacity = 1
            } completion: {
                isMovingMessage = false
            }
        }
    }

    private enum SwipeAxis {
        case horizontal
        case vertical
    }

    private func delete(_ message: InboxMessage) async {
        do {
            try await store.trash(message)
            index = min(index, max(0, messages.count - 1))
            InteractionFeedback.shared.perform(.destructive)
        } catch {
            deleteError = error.localizedDescription
            InteractionFeedback.shared.perform(.error)
        }
    }

    private func showNext() {
        guard index + 1 < messages.count else { return }
        InteractionFeedback.shared.perform(.page)
        withAnimation(.snappy) { index += 1; contentMode = .summary }
    }

    private func showPrevious() {
        guard index > 0 else { return }
        withAnimation(.snappy) { index -= 1; contentMode = .summary }
    }
}

private enum QueuePresentation: Hashable { case message, list }
private enum MessageContentMode: Hashable { case summary, fullEmail }

private struct MailListCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var store: InboxStore
    let message: InboxMessage
    var smartAttachment: RecognizedSmartAttachment? = nil
    var usesFlatSurface = true
    @AppStorage("inboxZeroMonochrome") private var monochrome = false

    var body: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
            HStack(alignment: .top, spacing: InboxDesign.Spacing.medium) {
                SenderMark(message: message, size: 46)
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.xSmall) {
                if dynamicTypeSize >= .xxxLarge {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.senderName).font(InboxDesign.Typography.font(.headline, weight: .semibold)).lineLimit(2)
                        Text(message.receivedAt, style: .date)
                            .font(InboxDesign.Typography.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: InboxDesign.Spacing.xSmall) {
                        Text(message.senderName).font(InboxDesign.Typography.font(.headline, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: InboxDesign.Spacing.small)
                        Text(message.receivedAt, style: .date)
                            .font(InboxDesign.Typography.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(message.subject)
                    .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                    .lineLimit(1)
                if smartAttachment == nil {
                    Text(message.displaySummary ?? message.snippet.htmlEntityDecoded)
                        .font(InboxDesign.Typography.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                }
            }

            if let smartAttachment {
                SmartAttachmentStrip(message: message, recognition: smartAttachment)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: InboxDesign.Spacing.small) {
                HStack(spacing: InboxDesign.Spacing.small) {
                    if store.accountEmails.count > 1 {
                        Text(MailboxPersona.name(for: message.accountEmail))
                            .font(InboxDesign.Typography.font(.caption2, weight: .semibold))
                            .foregroundStyle(monochrome ? Color.secondary : MailboxPersona.color(for: message.accountEmail))
                    }
                    if message.participatesInWorkflow != false {
                        LucideLabel(title: message.queue.rawValue, icon: message.queue.icon, iconSize: 12)
                            .font(InboxDesign.Typography.font(.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        LucideLabel(title: "Archive", icon: "archive", iconSize: 12)
                            .font(InboxDesign.Typography.font(.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let attachments = message.attachments, !attachments.isEmpty {
                        LucideLabel(title: attachments.count.formatted(), icon: "paperclip", iconSize: 12)
                            .font(InboxDesign.Typography.font(.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                LucideIcon(name: "chevron-right", size: 14).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .padding(InboxDesign.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MailListCardSurface(usesFlatSurface: usesFlatSurface))
        .accessibilityElement(children: .combine)
    }
}

private struct MailListCardSurface: ViewModifier {
    let usesFlatSurface: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesFlatSurface {
            content.inboxContentSurface(
                radius: InboxDesign.Radius.feature,
                level: .raised200
            )
        } else {
            content.inboxSurface(radius: InboxDesign.Radius.feature, material: .ultraThinMaterial)
        }
    }
}

private struct SmartAttachmentStrip: View {
    let message: InboxMessage
    let recognition: RecognizedSmartAttachment

    private var title: String {
        let filename = recognition.attachment.filename
            .replacingOccurrences(of: ".ics", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".pkpass", with: "", options: .caseInsensitive)
        return filename.isEmpty ? message.subject : filename
    }

    var body: some View {
        HStack(spacing: InboxDesign.Spacing.small) {
            LucideIcon(name: recognition.kind.iconName, size: 18)
                .frame(width: 28, height: 28)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                    .lineLimit(1)
                Text(recognition.kind.label)
                    .font(InboxDesign.Typography.font(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: InboxDesign.Spacing.xSmall)
            Text("ADD")
                .font(InboxDesign.Typography.font(.caption, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(minHeight: 30)
                .background(Color.accentColor, in: Capsule())
        }
        .padding(8)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct MailHTMLView: UIViewRepresentable {
    let html: String
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = true
        view.scrollView.alwaysBounceVertical = true
        view.scrollView.alwaysBounceHorizontal = false
        view.scrollView.showsHorizontalScrollIndicator = false
        view.scrollView.isDirectionalLockEnabled = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let appearanceKey = colorScheme == .dark ? "dark" : "light"
        let loadKey = "\(appearanceKey):\(html)"
        guard context.coordinator.loadedHTML != loadKey else { return }
        context.coordinator.loadedHTML = loadKey
        let fragment = html.replacingOccurrences(
            of: #"(?is)<!doctype[^>]*>|</?(?:html|head|body)(?:\s[^>]*)?>"#,
            with: "",
            options: .regularExpression
        )
        let safe = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        </head><body><div id="inbox-zero-email">
        \(fragment)
        </div>
        <style>
        :root{color-scheme:\(appearanceKey)}
        html,body{margin:0!important;width:100%!important;min-width:0!important;min-height:100%;overflow-x:hidden!important;-webkit-text-size-adjust:100%!important;text-size-adjust:100%!important}
        *,*::before,*::after{box-sizing:border-box!important}
        body{font:-apple-system-body;color:CanvasText;background:Canvas;padding:20px!important;line-height:1.55}
        #inbox-zero-email{width:100%;min-width:0}
        img,video,svg,canvas{height:auto;border-radius:18px}
        iframe,object,embed{max-width:100%!important}
        pre,code{white-space:pre-wrap!important;overflow-wrap:anywhere!important}
        a{color:LinkText;font-weight:600;overflow-wrap:anywhere}
        @media (prefers-color-scheme:dark){
          html,body{background:#000!important;color:#f5f5f7!important}
          #inbox-zero-email :where(p,span,div,td,th,li,h1,h2,h3,h4,h5,h6,strong,b,em,i,blockquote){color:#f5f5f7!important}
          #inbox-zero-email :where(table,tbody,thead,tfoot,tr,td,th,div,p){background-color:transparent!important}
          #inbox-zero-email a{color:#64a8ff!important}
          #inbox-zero-email hr{border-color:#3a3a3c!important}
        }
        </style>
        </body></html>
        """
        view.loadHTMLString(safe, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            fitContent(in: webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.fitContent(in: webView)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.fitContent(in: webView)
            }
        }

        private func fitContent(in webView: WKWebView) {
            let script = """
            (() => {
              const content = document.getElementById('inbox-zero-email');
              if (!content) return;

              const promoteImages = () => {
                content.querySelectorAll('img').forEach((image) => {
                  const candidates = ['data-src', 'data-original', 'data-lazy-src', 'data-image', 'data-url'];
                  const current = image.getAttribute('src') || '';
                  for (const attribute of candidates) {
                    const candidate = image.getAttribute(attribute);
                    if (candidate && (!current || current.startsWith('data:image/gif'))) {
                      image.setAttribute('src', candidate);
                      break;
                    }
                  }
                  const lazySet = image.getAttribute('data-srcset') || image.getAttribute('data-lazy-srcset');
                  if (lazySet && !image.getAttribute('srcset')) image.setAttribute('srcset', lazySet);
                  image.loading = 'eager';
                  image.decoding = 'async';
                  if (!image.dataset.inboxZeroObserved) {
                    image.dataset.inboxZeroObserved = 'true';
                    image.addEventListener('load', () => window.setTimeout(window.__inboxZeroFit, 0), { once: true });
                  }
                });
              };

              window.__inboxZeroFit = () => {
                content.style.transform = 'none';
                content.style.zoom = '1';
                content.style.width = 'auto';
                content.style.height = 'auto';

                const available = Math.max(document.body.clientWidth - 40, 1);
                const contentRect = content.getBoundingClientRect();
                let minLeft = contentRect.left;
                let maxRight = contentRect.right;
                let maxBottom = contentRect.bottom;
                content.querySelectorAll('*').forEach((element) => {
                  const rect = element.getBoundingClientRect();
                  if (rect.width > 0 && rect.height > 0) {
                    minLeft = Math.min(minLeft, rect.left);
                    maxRight = Math.max(maxRight, rect.right);
                    maxBottom = Math.max(maxBottom, rect.bottom);
                  }
                });

                const visualWidth = maxRight - Math.min(minLeft, contentRect.left);
                const naturalWidth = Math.max(content.scrollWidth, visualWidth, contentRect.width);
                if (naturalWidth > available + 1) {
                  const scale = available / naturalWidth;
                  // CSS zoom participates in WebKit layout. Unlike a transform,
                  // it also constrains percentage rows and late-loading artwork
                  // inside fixed-width newsletter tables.
                  content.style.zoom = String(scale);
                }
                document.documentElement.style.overflowX = 'hidden';
                document.body.style.overflowX = 'hidden';
                document.body.dataset.inboxZeroOverflow =
                  String(Math.max(0, document.documentElement.scrollWidth - document.documentElement.clientWidth));
              };

              promoteImages();
              window.__inboxZeroFit();
              if (!window.__inboxZeroWatchingResize) {
                window.__inboxZeroWatchingResize = true;
                window.addEventListener('resize', () => window.setTimeout(window.__inboxZeroFit, 80));
              }
              document.documentElement.style.overflowX = 'hidden';
              document.body.style.overflowX = 'hidden';
            })();
            """
            webView.evaluateJavaScript(script)
            webView.scrollView.setContentOffset(.zero, animated: false)
        }
    }
}

struct AllMailLibraryView: View {
    @Bindable var store: InboxStore
    @State private var filter = ""
    @State private var selectedMailbox: String?
    @State private var previewMessage: InboxMessage?
    @State private var showingComposer = ProcessInfo.processInfo.arguments.contains("-OpenCompose")
    @State private var mailActionsExpanded = ProcessInfo.processInfo.arguments.contains("-OpenAllMailMenu")

    private var visibleMessages: [InboxMessage] {
        let mailboxMessages = selectedMailbox.map { mailbox in
            store.messages.filter { $0.accountEmail?.caseInsensitiveCompare(mailbox) == .orderedSame }
        } ?? store.messages
        let sorted = mailboxMessages.sorted { $0.receivedAt > $1.receivedAt }
        guard !filter.isEmpty else { return sorted }
        return sorted.filter { $0.searchableText.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
                    HStack(alignment: .firstTextBaseline) {
            Text("All Mail")
                .font(InboxDesign.Typography.screenTitle)
                        Spacer()
                        Text(visibleMessages.count, format: .number)
                            .font(InboxDesign.Typography.font(.headline, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("Every message, including your archive")
                        .font(InboxDesign.Typography.screenSubtitle)
                        .foregroundStyle(.secondary)
                }

                if store.accountEmails.count > 1 {
                    Menu {
                        Button("All Mailboxes") { selectedMailbox = nil }
                        ForEach(store.accountEmails, id: \.self) { email in
                            Button(MailboxPersona.name(for: email)) { selectedMailbox = email }
                        }
                    } label: {
                        HStack(spacing: InboxDesign.Spacing.small) {
                            LucideIcon(name: "layers", size: 16)
                            Text(selectedMailbox.map { MailboxPersona.name(for: $0) } ?? "All Mailboxes")
                                .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                            LucideIcon(name: "chevron-down", size: 13)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, InboxDesign.Spacing.medium)
                        .frame(minHeight: InboxDesign.minimumTouchTarget)
                        .background(.thinMaterial, in: Capsule())
                    }
                    .accessibilityLabel("Mailbox filter")
                }

                HStack(spacing: InboxDesign.Spacing.medium) {
                    LucideIcon(name: "search", size: 19).foregroundStyle(.secondary)
                    TextField("Sender, subject, or email text", text: $filter)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { LucideIcon(name: "circle-x", size: 19) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(InboxDesign.Spacing.large)
                .inboxSurface(radius: InboxDesign.Radius.feature, material: .ultraThinMaterial)

                SwipeViewGroup {
                    ForEach(visibleMessages) { message in
                        AllMailMessageRow(store: store, message: message)
                    }
                }
            }
            .padding(.horizontal, InboxDesign.Spacing.large)
            .padding(.vertical, InboxDesign.Spacing.medium)
            .padding(.bottom, 104)
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if visibleMessages.isEmpty {
                libraryEmptyState
            }
        }
        .refreshable { await store.sync() }
        .overlay(alignment: .bottomTrailing) {
            MailContextActionMenu(
                context: .allMail,
                isExpanded: $mailActionsExpanded,
                compose: { showingComposer = true },
                sync: { Task { await store.sync() } }
            )
            .padding(.trailing, InboxDesign.Spacing.large)
            // TabView already reserves its floating bar. This smaller inset
            // keeps the contextual control at the same screen position as
            // the New Email attachment control above its send bar.
            .padding(.bottom, InboxDesign.Spacing.large)
        }
        .sheet(isPresented: $showingComposer) {
            NewMailComposer(store: store, initialAccount: selectedMailbox)
        }
#if DEBUG
        .navigationDestination(item: $previewMessage) { message in
            LibraryMessageView(store: store, message: message)
        }
        .task(id: store.messages.count) {
            guard ProcessInfo.processInfo.arguments.contains("-OpenAllMailMessage"),
                  previewMessage == nil,
                  let message = visibleMessages.first else { return }
            previewMessage = message
        }
#endif
    }

    @ViewBuilder
    private var libraryEmptyState: some View {
        if store.isSyncing || !store.hasCompletedInitialLoad {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Restoring your mail…")
            }
        } else if !filter.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else if store.accountEmails.isEmpty {
            ContentUnavailableView {
                LucideLabel(title: "Connect a mail account", icon: "mail-plus", iconSize: 26)
            } description: {
                Text("Connect an account in Settings to see your mail.")
            }
        } else if store.errorMessage != nil {
            ContentUnavailableView {
                LucideLabel(title: "Mail unavailable", icon: "cloud-off", iconSize: 26)
            } description: {
                Text("Pull to refresh or check the account in Settings.")
            }
        } else {
            ContentUnavailableView {
                LucideLabel(title: "No mail yet", icon: "inbox", iconSize: 26)
            } description: {
                Text("New and archived messages will appear here.")
            }
        }
    }
}

private struct AllMailMessageRow: View {
    @AppStorage("inboxZeroMonochrome") private var monochrome = false
    @Bindable var store: InboxStore
    let message: InboxMessage
    @State private var recognition: RecognizedSmartAttachment?
    @State private var walletPass: WalletPassPresentation?
    @State private var attachmentError: String?
    @State private var swipeIntent: AllMailSwipeIntent?

    var body: some View {
        SwipeView {
            ZStack(alignment: .bottomTrailing) {
                NavigationLink {
                    LibraryMessageView(store: store, message: message)
                } label: {
                    MailListCard(
                        store: store,
                        message: message,
                        smartAttachment: recognition,
                        usesFlatSurface: true
                    )
                }
                .buttonStyle(PressableButtonStyle())

                if let recognition {
                    if recognition.kind == .calendarInvitation {
                        NavigationLink {
                            LibraryMessageView(store: store, message: message)
                        } label: {
                            Color.clear.frame(width: 62, height: 46)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, InboxDesign.Spacing.large)
                        .padding(.bottom, 64)
                        .accessibilityLabel("Open calendar invitation")
                    } else {
                        Button {
                            Task { await addWalletPass(recognition.attachment) }
                        } label: {
                            Color.clear.frame(width: 62, height: 46)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, InboxDesign.Spacing.large)
                        .padding(.bottom, 64)
                        .accessibilityLabel("Add pass to Apple Wallet")
                    }
                }
            }
        } leadingActions: { _ in
            swipeAction(title: "Move", icon: "folder-input", color: .blue) {
                swipeIntent = .move
            }
        } trailingActions: { _ in
            swipeAction(title: "Delete", icon: "trash-2", color: .red) {
                swipeIntent = .delete
            }
        }
        .swipeMinimumDistance(18)
        .swipeActionsStyle(.mask)
        .swipeActionsMaskCornerRadius(InboxDesign.Radius.feature)
        .swipeActionCornerRadius(InboxDesign.Radius.feature)
        .swipeActionWidth(88)
        .swipeSpacing(InboxDesign.Spacing.small)
        .accessibilityAction(named: Text("Move Email")) { swipeIntent = .move }
        .accessibilityAction(named: Text("Delete Email")) { swipeIntent = .delete }
        .task(id: attachmentSignature) {
            recognition = await store.intelligence.recognizeSmartAttachment(in: message)
        }
        .sheet(item: $walletPass) { item in
            AddWalletPassView(pass: item.pass)
        }
        .confirmationDialog(
            swipeIntent == .delete ? "Delete Email?" : "Move Email",
            isPresented: Binding(
                get: { swipeIntent != nil },
                set: { if !$0 { swipeIntent = nil } }
            ),
            titleVisibility: .visible
        ) {
            if swipeIntent == .delete {
                Button("Delete", role: .destructive) {
                    swipeIntent = nil
                    Task { await deleteMessage() }
                }
            } else {
                ForEach(InboxQueue.allCases) { queue in
                    Button(queue.rawValue) {
                        swipeIntent = nil
                        move(to: queue)
                    }
                }
            }
            Button("Cancel", role: .cancel) { swipeIntent = nil }
        } message: {
            if swipeIntent == .delete {
                Text("This message will be moved to your mail provider’s Trash.")
            } else {
                Text("Choose a workflow queue for this message.")
            }
        }
        .alert("Unable to Complete Action", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "Please try again.")
        }
    }

    private func swipeAction(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        SwipeAction(action: action) { highlighted in
            VStack(spacing: InboxDesign.Spacing.small) {
                LucideIcon(name: icon, size: 19)
                Text(title)
                    .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(monochrome ? Color.primary : Color.white)
            .opacity(highlighted ? 0.72 : 1)
        } background: { highlighted in
            if monochrome {
                Color.primary.opacity(highlighted ? 0.16 : 0.10)
            } else {
                color.opacity(highlighted ? 0.82 : 1)
            }
        }
        .accessibilityLabel(title)
    }

    private func move(to queue: InboxQueue) {
        guard message.queue != queue else { return }
        store.move(message, to: queue)
        InteractionFeedback.shared.perform(queue == .done ? .success : .page)
    }

    @MainActor
    private func deleteMessage() async {
        do {
            try await store.trash(message)
            InteractionFeedback.shared.perform(.success)
        } catch {
            attachmentError = error.localizedDescription
            InteractionFeedback.shared.perform(.error)
        }
    }

    private var attachmentSignature: String {
        (message.attachments ?? []).map { "\($0.id):\($0.filename):\($0.mimeType)" }.joined(separator: "|")
    }

    @MainActor
    private func addWalletPass(_ attachment: InboxAttachment) async {
        do {
            let data = try await store.download(attachment, from: message)
            walletPass = WalletPassPresentation(pass: try PKPass(data: data))
            InteractionFeedback.shared.perform(.success)
        } catch {
            attachmentError = error.localizedDescription
            InteractionFeedback.shared.perform(.error)
        }
    }
}

private enum AllMailSwipeIntent: String, Identifiable {
    case move
    case delete

    var id: String { rawValue }
}

private struct WalletPassPresentation: Identifiable {
    let id = UUID()
    let pass: PKPass
}

private struct AddWalletPassView: UIViewControllerRepresentable {
    let pass: PKPass

    func makeUIViewController(context: Context) -> PKAddPassesViewController {
        PKAddPassesViewController(pass: pass)!
    }

    func updateUIViewController(_ uiViewController: PKAddPassesViewController, context: Context) {}
}

struct LibraryMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: InboxStore
    let message: InboxMessage
    @State private var activeComposer: ComposeMode?
    @State private var contentMode: MessageContentMode = .summary
    @State private var generatedSummary: String?
    @State private var showingDeleteConfirmation = false
    @State private var deleteError: String?
    @State private var readerActionsExpanded = ProcessInfo.processInfo.arguments.contains("-OpenReaderActions")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MessageReaderHeader(message: message)

            EmailContentModePicker(selection: $contentMode)

            if contentMode == .fullEmail {
                VStack(spacing: 0) {
                    if let attachments = message.attachments, !attachments.isEmpty {
                        MessageFilesView(store: store, message: message, attachments: attachments)
                            .padding(.horizontal, InboxDesign.Spacing.large)
                            .padding(.top, InboxDesign.Spacing.medium)
                            .padding(.bottom, InboxDesign.Spacing.medium)
                    }
                    MailHTMLView(html: message.bodyHTML)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                        if let invitation = message.attachments?.first(where: \.isCalendarInvitation) {
                            CalendarInvitationCard(store: store, message: message, attachment: invitation)
                        } else {
                            VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
                            LucideLabel(
                                title: store.summaryIsAI(for: message) ? "AI Summary" : "Email Preview",
                                icon: store.summaryIsAI(for: message) ? "astroid" : "align-left",
                                iconSize: 14
                            )
                                .font(InboxDesign.Typography.font(.caption, weight: .bold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                            if let summary = generatedSummary.flatMap({ LocalIntelligence.isGeneratedArtifact($0) ? nil : $0 }) ?? message.displaySummary {
                                SummaryText(summary: summary)
                            } else {
                                HStack(spacing: InboxDesign.Spacing.small) {
                                    ProgressView().controlSize(.small)
                                    Text("Summarizing on device…").foregroundStyle(.secondary)
                                }
                            }
                            }
                            .padding(InboxDesign.Spacing.large)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .inboxContentSurface()
                        }
                    }
                    .padding(InboxDesign.Spacing.large)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("Email")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Move this email to Trash?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Email", role: .destructive) {
                Task {
                    do {
                        try await store.trash(message)
                        InteractionFeedback.shared.perform(.destructive)
                        dismiss()
                    } catch {
                        deleteError = error.localizedDescription
                        InteractionFeedback.shared.perform(.error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can recover it later from your mail provider’s Trash.")
        }
        .alert("Unable to Delete", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "Please try again.")
        }
        .overlay(alignment: .bottomTrailing) {
            MailContextActionMenu(
                context: .reader,
                isExpanded: $readerActionsExpanded,
                reply: { activeComposer = .reply },
                replyAll: { activeComposer = .replyAll },
                forward: { activeComposer = .forward },
                moveActions: InboxQueue.allCases.map { queue in
                    MailContextMoveAction(
                        title: queue.rawValue,
                        icon: queue.icon,
                        action: { store.move(message, to: queue) }
                    )
                } + [
                    MailContextMoveAction(
                        title: "Delete Email",
                        icon: "trash-2",
                        role: .destructive,
                        action: { showingDeleteConfirmation = true }
                    )
                ]
            )
            .padding(.trailing, InboxDesign.Spacing.large)
            .padding(.bottom, InboxDesign.Spacing.large)
        }
        .onChange(of: contentMode) { _, _ in
            readerActionsExpanded = false
        }
        .sheet(item: $activeComposer) { mode in
            ReplyComposer(store: store, message: message, mode: mode)
        }
        .task(id: message.id) {
            generatedSummary = await store.summary(for: message)
        }
    }
}

/// Canonical reader header shared by All Mail and every workflow queue.
/// Queue navigation is deliberately kept outside the sender card so the
/// identity, subject, date, surface and recipient disclosure never change.
private struct MessageReaderHeader: View {
    let message: InboxMessage
    var queuePosition: String? = nil
    var canShowPrevious = false
    var canShowNext = false
    var showPrevious: (() -> Void)? = nil
    var showNext: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
            EmailIdentityPanel(message: message, dateStyle: .date) { EmptyView() }
            MessageEnvelopeDisclosure(message: message)

            if let queuePosition {
                HStack(spacing: InboxDesign.Spacing.xSmall) {
                    Text(queuePosition)
                        .font(InboxDesign.Typography.font(.caption).monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer(minLength: InboxDesign.Spacing.small)

                    Button { showPrevious?() } label: {
                        LucideIcon(name: "chevron-up", size: 16)
                            .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .disabled(!canShowPrevious)
                    .accessibilityLabel("Previous email")

                    Button { showNext?() } label: {
                        LucideIcon(name: "chevron-down", size: 16)
                            .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .disabled(!canShowNext)
                    .accessibilityLabel("Next email")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, InboxDesign.Spacing.large)
        .padding(.top, InboxDesign.Spacing.medium)
        .padding(.bottom, InboxDesign.Spacing.medium)
    }
}

/// One canonical sender/subject hierarchy for queue detail and All Mail detail.
/// Keeping this anatomy shared prevents typography, geometry, and surface depth
/// from drifting as either reader evolves.
private struct EmailIdentityPanel<Accessory: View>: View {
    enum DateStyle { case time, date }

    let message: InboxMessage
    let dateStyle: DateStyle
    var position: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: InboxDesign.Spacing.medium) {
            SenderMark(message: message, size: 48)

            VStack(alignment: .leading, spacing: InboxDesign.Spacing.xSmall) {
                Text(message.senderName)
                    .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                    .lineLimit(2)

                Text(message.senderAddress)
                    .font(InboxDesign.Typography.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(message.subject)
                    .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                    .lineLimit(2)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Group {
                    switch dateStyle {
                    case .time:
                        Text(message.receivedAt, style: .time)
                    case .date:
                        Text(message.receivedAt, style: .date)
                    }
                }
                .font(InboxDesign.Typography.font(.caption))
                .foregroundStyle(.secondary)

                if let position {
                    Text(position)
                        .font(InboxDesign.Typography.font(.caption).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                accessory()
            }
        }
        .padding(InboxDesign.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inboxContentSurface(radius: InboxDesign.Radius.card, level: .raised200)
        .accessibilityElement(children: .contain)
    }
}

/// The same mode control is used in every message reader so its geometry never
/// shifts when moving between a queue and All Mail.
private struct EmailContentModePicker: View {
    @Binding var selection: MessageContentMode

    var body: some View {
        Picker("Email content", selection: $selection) {
            Text("Summary").tag(MessageContentMode.summary)
            Text("Full Email").tag(MessageContentMode.fullEmail)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, InboxDesign.Spacing.large)
        .padding(.vertical, InboxDesign.Spacing.small)
    }
}

private struct MessageEnvelopeDisclosure: View {
    let message: InboxMessage
    @State private var isExpanded = false

    private var recipients: [MailParticipant] {
        (message.toRecipients ?? []) + (message.ccRecipients ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: InboxDesign.Spacing.small) {
                Text(collapsedLabel)
                    .font(InboxDesign.Typography.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer(minLength: InboxDesign.Spacing.small)
                    LucideIcon(name: isExpanded ? "chevron-up" : "chevron-down", size: 15)
                        .foregroundStyle(.secondary)
                        .frame(width: InboxDesign.minimumTouchTarget, height: InboxDesign.minimumTouchTarget)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
                    detailRow("From", participants: [.init(name: message.senderName, address: message.senderAddress)])
                    detailRow("To", participants: message.toRecipients ?? [])
                    if !(message.ccRecipients ?? []).isEmpty { detailRow("Cc", participants: message.ccRecipients ?? []) }
                    if !(message.bccRecipients ?? []).isEmpty { detailRow("Bcc", participants: message.bccRecipients ?? []) }
                    if let replyTo = message.replyTo { detailRow("Reply-To", participants: [replyTo]) }
                    HStack(alignment: .firstTextBaseline, spacing: InboxDesign.Spacing.small) {
                        Text("Date")
                            .frame(width: 72, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(InboxDesign.Typography.font(.caption))
                .padding(InboxDesign.Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .inboxContentSurface(radius: InboxDesign.Radius.card, level: .raised200)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(isExpanded ? "Hide message details" : "Show message recipients and details")
    }

    private var collapsedLabel: String {
        guard !recipients.isEmpty else { return "View message details" }
        let names = recipients.prefix(3).map(\.displayName)
        let remainder = recipients.count - names.count
        return "to " + names.joined(separator: ", ") + (remainder > 0 ? ", +\(remainder)" : "")
    }

    @ViewBuilder
    private func detailRow(_ label: String, participants: [MailParticipant]) -> some View {
        if !participants.isEmpty {
            HStack(alignment: .top, spacing: InboxDesign.Spacing.small) {
                Text(label).frame(width: 72, alignment: .leading).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(participants) { participant in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(participant.displayName).fontWeight(.medium)
                            if !participant.name.isEmpty {
                                Text(participant.address).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SummaryText: View {
    let summary: String

    private var sentences: [String] {
        let cleaned = summary.htmlEntityDecoded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var parts: [String] = []
        cleaned.enumerateSubstrings(
            in: cleaned.startIndex..<cleaned.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let sentence = cleaned[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { parts.append(sentence) }
        }
        return parts.isEmpty ? [cleaned] : parts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
            ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                Text(sentence)
                    .font(InboxDesign.Typography.font(.body, weight: .medium))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MessageFilesView: View {
    @Bindable var store: InboxStore
    let message: InboxMessage
    let attachments: [InboxAttachment]

    private var invitation: InboxAttachment? {
        attachments.first(where: \.isCalendarInvitation)
    }

    private var files: [InboxAttachment] {
        attachments.filter { !$0.isCalendarInvitation }
    }

    var body: some View {
        VStack(spacing: InboxDesign.Spacing.small) {
            if let invitation {
                CalendarInvitationCard(store: store, message: message, attachment: invitation)
            }
            if !files.isEmpty {
                MessageAttachmentsView(store: store, message: message, attachments: files)
            }
        }
    }
}

private struct CalendarInvitationCard: View {
    @Bindable var store: InboxStore
    let message: InboxMessage
    let attachment: InboxAttachment

    @AppStorage("inboxZeroMonochrome") private var monochrome = false
    @State private var invitation: ParsedCalendarInvitation?
    @State private var conflicts: [EKEvent] = []
    @State private var isLoading = true
    @State private var response: CalendarInvitationResponse?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
            Button(action: openCalendar) {
                HStack(alignment: .top, spacing: InboxDesign.Spacing.medium) {
                    LucideIcon(name: "calendar-days", size: 21)
                        .foregroundStyle(monochrome ? Color.primary : Color.red)
                        .frame(width: 44, height: 44)
                        .background(
                            monochrome ? Color.primary.opacity(0.08) : Color.red.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: InboxDesign.Radius.compact)
                        )
                    VStack(alignment: .leading, spacing: InboxDesign.Spacing.xSmall) {
                        Text(invitation?.title ?? message.subject).font(InboxDesign.Typography.font(.headline, weight: .semibold)).lineLimit(2)
                        if let invitation {
                            Text(invitation.dateDescription)
                                .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                            Text(invitation.timeDescription).font(InboxDesign.Typography.font(.subheadline)).foregroundStyle(.secondary)
                            if let location = invitation.location, !location.isEmpty {
                                LucideLabel(title: location, icon: "map-pin", iconSize: 14)
                                    .font(InboxDesign.Typography.font(.caption)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        } else {
                            HStack(spacing: InboxDesign.Spacing.small) {
                                ProgressView().controlSize(.small)
                                Text("Reading invitation…")
                            }
                            .font(InboxDesign.Typography.font(.subheadline)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: InboxDesign.Spacing.small)
                    LucideIcon(name: "arrow-up-right", size: 16)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(invitation == nil)
            .accessibilityHint("Opens Calendar on this date")

            if invitation != nil {
                Divider()
                HStack(spacing: InboxDesign.Spacing.small) {
                    LucideIcon(name: conflicts.isEmpty ? "calendar-check" : "calendar-clock", size: 17)
                        .foregroundStyle(
                            monochrome ? Color.secondary : (conflicts.isEmpty ? Color.green : Color.orange)
                        )
                    Text(conflictDescription)
                    Spacer()
                }
                .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)

                if let response {
                    HStack(spacing: InboxDesign.Spacing.small) {
                        LucideIcon(name: response.icon, size: 17)
                        Text(response.confirmation).font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                        Spacer()
                        Button("Open Calendar", action: openCalendar)
                            .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(monochrome ? Color.primary : response.color)
                    .frame(minHeight: InboxDesign.minimumTouchTarget)
                } else {
                    HStack(spacing: InboxDesign.Spacing.small) {
                        responseButton(.declined)
                        responseButton(.tentative)
                        responseButton(.accepted, isPrimary: true)
                    }
                }
            }
        }
        .padding(InboxDesign.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inboxContentSurface(radius: InboxDesign.Radius.feature)
        .task(id: attachment.id) { await loadInvitation() }
        .alert("Calendar Invitation", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private func responseButton(_ choice: CalendarInvitationResponse, isPrimary: Bool = false) -> some View {
        Button { Task { await respond(choice) } } label: {
            Text(choice.title)
                .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                .foregroundStyle(
                    monochrome
                        ? (isPrimary ? Color(uiColor: .systemBackground) : Color.primary)
                        : Color.white
                )
                .frame(maxWidth: .infinity, minHeight: InboxDesign.minimumTouchTarget)
                .background(
                    monochrome
                        ? (isPrimary ? Color.primary : Color.primary.opacity(0.08))
                        : choice.color,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(
                            monochrome && !isPrimary ? Color.primary.opacity(0.18) : Color.clear,
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .disabled(isLoading || invitation == nil)
        .opacity(isLoading || invitation == nil ? 0.5 : 1)
    }

    @MainActor
    private func loadInvitation() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await store.download(attachment, from: message)
            guard let parsed = ParsedCalendarInvitation(data: data, fallbackTitle: message.subject) else {
                throw CalendarInvitationError.unreadable
            }
            invitation = parsed
            if let saved = UserDefaults.standard.string(forKey: responseKey) {
                response = CalendarInvitationResponse(rawValue: saved)
            }
            let eventStore = EKEventStore()
            if try await eventStore.requestFullAccessToEvents() {
                conflicts = calendarConflicts(for: parsed, in: eventStore)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func respond(_ choice: CalendarInvitationResponse) async {
        guard let invitation else { return }
        if choice == .declined {
            response = choice
            UserDefaults.standard.set(choice.rawValue, forKey: responseKey)
            InteractionFeedback.shared.perform(.success)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let eventStore = EKEventStore()
            guard try await eventStore.requestFullAccessToEvents() else {
                throw CalendarInvitationError.permissionDenied
            }
            let event = EKEvent(eventStore: eventStore)
            event.calendar = eventStore.defaultCalendarForNewEvents
            event.title = invitation.title
            event.startDate = invitation.start
            event.endDate = invitation.end
            event.isAllDay = invitation.isAllDay
            event.location = invitation.location
            event.availability = choice == .tentative ? .tentative : .busy
            event.notes = "Added from an inbox.Zer0 invitation sent by \(message.senderName)."
            try eventStore.save(event, span: .thisEvent, commit: true)
            response = choice
            UserDefaults.standard.set(choice.rawValue, forKey: responseKey)
            InteractionFeedback.shared.perform(.success)
        } catch {
            errorMessage = error.localizedDescription
            InteractionFeedback.shared.perform(.error)
        }
    }

    private func calendarConflicts(for invitation: ParsedCalendarInvitation, in eventStore: EKEventStore) -> [EKEvent] {
        let end = max(invitation.end, invitation.start.addingTimeInterval(60))
        let predicate = eventStore.predicateForEvents(withStart: invitation.start, end: end, calendars: nil)
        return eventStore.events(matching: predicate).filter {
            !($0.title == invitation.title && abs($0.startDate.timeIntervalSince(invitation.start)) < 60)
        }
    }

    private var conflictDescription: String {
        guard let first = conflicts.first else { return "No conflicting appointments" }
        if conflicts.count == 1 { return "Conflicts with \(first.title ?? "another appointment")" }
        return "Conflicts with \(first.title ?? "another appointment") and \(conflicts.count - 1) more"
    }

    private func openCalendar() {
        guard let invitation,
              let url = URL(string: "calshow:\(invitation.calendarOpenDate.timeIntervalSinceReferenceDate)") else { return }
        UIApplication.shared.open(url)
    }

    private var responseKey: String { "calendarInvitationResponse.\(message.id).\(attachment.id)" }
}

private enum CalendarInvitationResponse: String, Equatable {
    case accepted, tentative, declined

    var title: String { self == .accepted ? "Accept" : self == .tentative ? "Maybe" : "Decline" }
    var confirmation: String {
        self == .accepted ? "Added to Calendar" : self == .tentative ? "Added as tentative" : "Declined on this device"
    }
    var icon: String { self == .accepted ? "calendar-check" : self == .tentative ? "calendar-clock" : "calendar-x" }
    var color: Color { self == .accepted ? .green : self == .tentative ? .orange : .red }
}

private struct ParsedCalendarInvitation {
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let isAllDay: Bool
    let timeZone: TimeZone

    /// Calendar's `calshow` handoff is an absolute instant. Rebuild the
    /// invitation's displayed year/month/day in the device time zone and use
    /// midday so the handoff cannot drift to the preceding or following day
    /// because of a midnight or cross-time-zone conversion.
    var calendarOpenDate: Date {
        var invitationCalendar = Calendar(identifier: .gregorian)
        invitationCalendar.timeZone = timeZone
        var components = invitationCalendar.dateComponents([.year, .month, .day], from: start)
        components.hour = 12
        components.minute = 0
        components.second = 0

        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current
        return deviceCalendar.date(from: components) ?? start
    }

    var dateDescription: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMMdyyyy")
        return formatter.string(from: start)
    }

    var timeDescription: String {
        guard !isAllDay else { return "All-day event" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }

    init?(data: Data, fallbackTitle: String) {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let unfolded = raw.replacingOccurrences(of: "\\r?\\n[ \\t]", with: "", options: .regularExpression)
        let allLines = unfolded.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let eventStart = allLines.firstIndex(where: { $0.caseInsensitiveCompare("BEGIN:VEVENT") == .orderedSame }),
              let eventEnd = allLines[eventStart...].firstIndex(where: { $0.caseInsensitiveCompare("END:VEVENT") == .orderedSame }),
              eventStart < eventEnd else { return nil }
        let lines = Array(allLines[eventStart...eventEnd])

        func sourceLine(_ key: String) -> String? {
            lines.first { line in
                let name = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                return name == key || name.hasPrefix("\(key);")
            }
        }

        func value(_ key: String) -> String? {
            guard let line = sourceLine(key), let colon = line.firstIndex(of: ":") else { return nil }
            return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let calendarTimeZone = allLines.first(where: { $0.uppercased().hasPrefix("X-WR-TIMEZONE:") })
            .flatMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return String(line[line.index(after: colon)...])
            }
            .flatMap(Self.resolvedTimeZone)

        func date(_ key: String) -> (date: Date, timeZone: TimeZone)? {
            guard let line = sourceLine(key), let source = value(key) else { return nil }
            let property = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? key
            let timezoneIdentifier = property.split(separator: ";")
                .map(String.init)
                .first(where: { $0.uppercased().hasPrefix("TZID=") })?
                .dropFirst("TZID=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let explicitTimeZone = timezoneIdentifier.flatMap(Self.resolvedTimeZone)
            let isUTC = source.uppercased().hasSuffix("Z")
            let parsedTimeZone = isUTC ? TimeZone(secondsFromGMT: 0)! : explicitTimeZone ?? calendarTimeZone ?? .current
            let formats = isUTC
                ? ["yyyyMMdd'T'HHmmss.SSS'Z'", "yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmm'Z'"]
                : ["yyyyMMdd'T'HHmmss.SSSZ", "yyyyMMdd'T'HHmmssZ", "yyyyMMdd'T'HHmmss.SSS", "yyyyMMdd'T'HHmmss", "yyyyMMdd'T'HHmm", "yyyyMMdd"]
            for format in formats {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                formatter.timeZone = parsedTimeZone
                formatter.isLenient = false
                if let parsed = formatter.date(from: source) { return (parsed, parsedTimeZone) }
            }
            return nil
        }

        guard let parsedStart = date("DTSTART"),
              Self.isPlausibleEventDate(parsedStart.date, in: parsedStart.timeZone) else { return nil }
        let allDay = sourceLine("DTSTART")?.contains("VALUE=DATE") == true || value("DTSTART")?.count == 8
        self.title = value("SUMMARY")?.replacingOccurrences(of: "\\,", with: ",") ?? fallbackTitle
        self.start = parsedStart.date
        let parsedEnd = date("DTEND")?.date
        self.end = parsedEnd.flatMap { Self.isPlausibleEventDate($0, in: parsedStart.timeZone) && $0 >= parsedStart.date ? $0 : nil }
            ?? parsedStart.date.addingTimeInterval(allDay ? 86_400 : 3_600)
        self.location = value("LOCATION")?.replacingOccurrences(of: "\\,", with: ",")
        self.isAllDay = allDay
        self.timeZone = parsedStart.timeZone
    }

    nonisolated private static func resolvedTimeZone(_ rawIdentifier: String) -> TimeZone? {
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let exact = TimeZone(identifier: identifier) { return exact }
        let aliases = [
            "Arabian Standard Time": "Asia/Dubai",
            "Gulf Standard Time": "Asia/Dubai",
            "UTC": "UTC",
            "GMT Standard Time": "Europe/London",
            "Eastern Standard Time": "America/New_York",
            "Central Standard Time": "America/Chicago",
            "Mountain Standard Time": "America/Denver",
            "Pacific Standard Time": "America/Los_Angeles"
        ]
        return aliases[identifier].flatMap(TimeZone.init(identifier:))
    }

    nonisolated private static func isPlausibleEventDate(_ date: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let year = calendar.dateComponents([.year], from: date).year else { return false }
        return (2000...2100).contains(year)
    }
}

private enum CalendarInvitationError: LocalizedError {
    case unreadable
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .unreadable: "This invitation could not be read."
        case .permissionDenied: "Calendar access is required to add this invitation."
        }
    }
}

private struct MessageAttachmentsView: View {
    @Bindable var store: InboxStore
    let message: InboxMessage
    let attachments: [InboxAttachment]
    @State private var loadingIDs: Set<String> = []
    @State private var previewItem: AttachmentPreviewItem?
    @State private var exportDocument: AttachmentFileDocument?
    @State private var exportFilename = "Attachment"
    @State private var showingExporter = false
    @State private var showingAllAttachments = false
    @State private var isExpanded = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? InboxDesign.Spacing.medium : 0) {
            Button {
                withAnimation(.snappy(duration: 0.24)) { isExpanded.toggle() }
            } label: {
                HStack {
                LucideLabel(
                    title: attachments.count == 1 ? "1 Attachment" : "\(attachments.count) Attachments",
                    icon: "paperclip",
                    iconSize: 15
                )
                .font(InboxDesign.Typography.font(.caption, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                Spacer()
                    LucideIcon(name: "chevron-down", size: 15)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(isExpanded ? "Collapse attachments" : "Show attachments")

            if isExpanded {
                ForEach(Array(attachments.prefix(3))) { attachment in
                    attachmentRow(attachment)
                }
                if attachments.count > 3 {
                    Button("View all \(attachments.count) attachments") { showingAllAttachments = true }
                        .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, InboxDesign.Spacing.xSmall)
                }
            }
        }
        .padding(isExpanded ? InboxDesign.Spacing.large : InboxDesign.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inboxSurface(radius: InboxDesign.Radius.feature, material: .ultraThinMaterial)
        .sheet(item: $previewItem) { item in
            AttachmentPreviewSheet(url: item.url)
        }
        .sheet(isPresented: $showingAllAttachments) {
            NavigationStack {
                ScrollView {
                    LazyVStack(spacing: InboxDesign.Spacing.small) {
                        ForEach(attachments) { attachment in
                            attachmentRow(attachment)
                                .padding(.horizontal, InboxDesign.Spacing.large)
                                .padding(.vertical, InboxDesign.Spacing.xSmall)
                        }
                    }
                    .padding(.vertical, InboxDesign.Spacing.medium)
                }
                .navigationTitle("Attachments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingAllAttachments = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("Attachment", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func attachmentRow(_ attachment: InboxAttachment) -> some View {
        HStack(spacing: InboxDesign.Spacing.medium) {
            Button { fetch(attachment, for: .preview) } label: {
                HStack(spacing: InboxDesign.Spacing.medium) {
                    ZStack {
                        RoundedRectangle(cornerRadius: InboxDesign.Radius.compact)
                            .fill(.thinMaterial)
                        if loadingIDs.contains(attachment.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            LucideIcon(name: attachmentIcon(for: attachment.mimeType), size: 21)
                        }
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.filename)
                            .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                            .lineLimit(1)
                        Text(attachmentDetail(attachment))
                            .font(InboxDesign.Typography.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loadingIDs.contains(attachment.id))
            .accessibilityHint("Previews attachment")

            Button { fetch(attachment, for: .save) } label: {
                LucideIcon(name: "download", size: 19)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(loadingIDs.contains(attachment.id))
            .accessibilityLabel("Save \(attachment.filename) to Files")
        }
    }

    private func attachmentDetail(_ attachment: InboxAttachment) -> String {
        let type = attachment.mimeType.split(separator: "/").last.map(String.init)?.uppercased() ?? "FILE"
        guard attachment.size > 0 else { return type }
        return "\(type) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))"
    }

    private func attachmentIcon(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "image" }
        if mimeType == "application/pdf" { return "file-text" }
        if mimeType.hasPrefix("video/") { return "file-video" }
        if mimeType.hasPrefix("audio/") { return "file-audio" }
        if mimeType.contains("zip") || mimeType.contains("compressed") { return "file-archive" }
        return "file"
    }

    private func fetch(_ attachment: InboxAttachment, for action: AttachmentAction) {
        loadingIDs.insert(attachment.id)
        errorMessage = nil
        Task {
            defer { loadingIDs.remove(attachment.id) }
            do {
                let data = try await store.download(attachment, from: message)
                switch action {
                case .preview:
                    let url = try temporaryURL(for: attachment.filename, data: data)
                    previewItem = AttachmentPreviewItem(url: url)
                case .save:
                    exportFilename = safeFilename(attachment.filename)
                    exportDocument = AttachmentFileDocument(data: data)
                    showingExporter = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func temporaryURL(for filename: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-Zer0-attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(safeFilename(filename))")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func safeFilename(_ filename: String) -> String {
        let value = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return value.isEmpty ? "Attachment" : value
    }
}

private extension InboxAttachment {
    var isCalendarInvitation: Bool {
        mimeType.lowercased().contains("text/calendar") || filename.lowercased().hasSuffix(".ics")
    }
}

private enum AttachmentAction { case preview, save }

private struct AttachmentPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            AttachmentQuickLook(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
    }
}

private struct AttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: PreviewItem
        init(url: URL) { item = PreviewItem(url: url) }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }
    }

    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        init(url: URL) { previewItemURL = url }
    }
}

private struct AttachmentFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum ComposeMode: String, Identifiable {
    case reply
    case replyAll
    case forward

    var id: String { rawValue }
}

private struct ReplyComposer: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("inboxZeroMonochrome") private var monochrome = false
    @Bindable var store: InboxStore
    let message: InboxMessage
    let mode: ComposeMode
    @State private var instruction = ""
    @State private var draft = ""
    @State private var isGenerating = false
    @State private var isSending = false
    @State private var error: String?
    @State private var speech = SpeechTranscriber()
    @State private var recipient = ""
    @State private var attachments: [OutgoingAttachment] = []
    @State private var showingFileImporter = false
    @FocusState private var draftIsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                    messageContext
                    if mode == .forward { recipientField }
                    intentComposer
                    draftEditor
                    attachmentSection
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(InboxDesign.Typography.font(.caption))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(error)")
                    }
                }
                .padding(.horizontal, InboxDesign.Spacing.large)
                .padding(.top, InboxDesign.Spacing.medium)
                .padding(.bottom, 110)
            }
            .background(AtmosphereBackground())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(mode == .forward ? "Forward" : (mode == .replyAll ? "Reply All" : "Reply")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { LucideIcon(name: "x", size: 20) }
                        .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) { sendBar }
            .onChange(of: speech.transcript) { _, value in instruction = value }
            .task { draft = mode == .forward ? "" : (message.suggestedReply ?? "") }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                importFiles(result)
            }
            .onDisappear {
                speech.stop()
            }
        }
    }

    private var messageContext: some View {
        HStack(spacing: InboxDesign.Spacing.medium) {
            SenderMark(message: message, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(mode == .forward ? "Forward from \(message.senderName)" : (mode == .replyAll ? "Reply all" : "Reply to \(message.senderName)"))
                    .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                Text(message.subject)
                    .font(InboxDesign.Typography.font(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(InboxDesign.Spacing.medium)
        .inboxSurface(radius: InboxDesign.Radius.card, material: .ultraThinMaterial)
    }

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
            Text("TO").font(InboxDesign.Typography.font(.caption, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: InboxDesign.Spacing.small) {
                LucideIcon(name: "mail", size: 18)
                    .foregroundStyle(.secondary)
                TextField("Recipient email address", text: $recipient)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
            }
            .padding(.vertical, InboxDesign.Spacing.small)

            if !normalizedRecipient.isEmpty && !recipientIsValid {
                Text("Enter a complete email address")
                    .font(InboxDesign.Typography.font(.caption))
                    .foregroundStyle(.red)
            }
        }
        .padding(InboxDesign.Spacing.medium)
        .inboxSurface(radius: InboxDesign.Radius.control, material: .ultraThinMaterial)
    }

    private var intentComposer: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
            HStack {
                Text("WHAT SHOULD IT SAY?")
                    .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                LucideIcon(name: "astroid", size: 17).foregroundStyle(.secondary)
            }
            TextField("Type an instruction or use your voice", text: $instruction, axis: .vertical)
                .lineLimit(2...5)
                .font(InboxDesign.Typography.font(.body))
            if isGenerating { ProgressView("Drafting…") }
        }
        .padding(InboxDesign.Spacing.medium)
        .inboxSurface(radius: InboxDesign.Radius.card, material: .ultraThinMaterial)
    }

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
            HStack {
                LucideIcon(name: "astroid", size: 17)
                Text("DRAFT").font(InboxDesign.Typography.font(.caption, weight: .semibold))
                Spacer()
                if !draft.isEmpty {
                    Button {
                        draftIsFocused = true
                        InteractionFeedback.shared.perform(.selection, sound: false)
                    } label: {
                        LucideLabel(title: "Edit draft", icon: "pencil-line", iconSize: 14)
                            .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                            .frame(minHeight: InboxDesign.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityHint("Places the cursor in the generated draft so you can override it")
                }
            }
            .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Your draft will appear here")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(InboxDesign.Typography.font(.body))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .focused($draftIsFocused)
                    .accessibilityHint("Edit or replace the generated message before sending")
            }
            if readyToSend && !isGenerating && !isSending {
                HStack(spacing: InboxDesign.Spacing.small) {
                    Button { Task { await rewriteDraft() } } label: {
                        LucideLabel(title: "Rewrite", icon: "refresh-cw", iconSize: 16)
                            .frame(maxWidth: .infinity, minHeight: InboxDesign.minimumTouchTarget)
                    }
                    Button { Task { await redictateDraft() } } label: {
                        LucideLabel(title: "Re-dictate", icon: "audio-lines", iconSize: 16)
                            .frame(maxWidth: .infinity, minHeight: InboxDesign.minimumTouchTarget)
                    }
                }
                .buttonStyle(.plain)
                .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().stroke(.primary.opacity(0.08), lineWidth: 0.5) }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(InboxDesign.Spacing.medium)
        .inboxSurface(radius: InboxDesign.Radius.card, material: .ultraThinMaterial)
    }

    @ViewBuilder
    private var sendBar: some View {
        if showsVoicePill {
            Button { Task { await performPrimaryComposeAction() } } label: {
                FrostedVoicePill(
                    isRecording: speech.isRecording,
                    accent: monochrome ? .primary : .blue,
                    idleTitle: "Dictate",
                    listeningTitle: "Listening…"
                )
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(speech.isRecording ? "Finish dictation" : "Dictate reply instruction")
            .accessibilityHint(primaryActionHint)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, InboxDesign.Spacing.large)
            .padding(.top, InboxDesign.Spacing.small)
            .padding(.bottom, InboxDesign.Spacing.small)
        } else {
            Button { Task { await performPrimaryComposeAction() } } label: {
                HStack(spacing: InboxDesign.Spacing.small) {
                    if isGenerating || isSending {
                        ProgressView().tint(.white)
                    } else {
                        LucideIcon(name: primaryActionIcon, size: 20)
                    }
                    Text(primaryActionTitle).font(InboxDesign.Typography.font(.headline, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Capsule())
            }
            .buttonStyle(.borderedProminent)
            .tint(monochrome ? Color.primary : .black)
            .disabled(isGenerating || isSending || (readyToSend && mode == .forward && !recipientIsValid))
            .animation(.snappy(duration: 0.22), value: primaryActionTitle)
            .accessibilityHint(primaryActionHint)
            .padding(.horizontal, InboxDesign.Spacing.large)
            .padding(.top, InboxDesign.Spacing.small)
            .padding(.bottom, InboxDesign.Spacing.small)
        }
    }

    private var showsVoicePill: Bool {
        speech.isRecording || (!readyToSend && instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating)
    }

    private var readyToSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var primaryActionTitle: String {
        if isSending { return "Sending…" }
        if isGenerating { return "Drafting…" }
        if speech.isRecording { return "Finish Dictation" }
        if readyToSend { return mode == .forward ? "Forward Email" : (mode == .replyAll ? "Send Reply All" : "Send Reply") }
        if !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Create Draft" }
        return "Dictate"
    }

    private var primaryActionIcon: String {
        if speech.isRecording { return "audio-waveform" }
        if readyToSend { return "send-horizontal" }
        if !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "astroid" }
        return "audio-lines"
    }

    private var primaryActionHint: String {
        if speech.isRecording { return "Stops recording and creates an editable draft" }
        if readyToSend { return "Sends the editable draft after confirmation" }
        if !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Creates an editable AI draft" }
        return "Starts voice dictation"
    }

    private func performPrimaryComposeAction() async {
        if speech.isRecording {
            await toggleDictation()
        } else if readyToSend {
            await send()
        } else if !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await generate()
        } else {
            await toggleDictation()
        }
    }

    private func rewriteDraft() async {
        let currentDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentDraft.isEmpty else { return }
        isGenerating = true
        let guidance = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let rewriteInstruction = guidance.isEmpty
            ? "Rewrite this reply so it is concise, natural, and polished while preserving its meaning: \(currentDraft)"
            : "Create a fresh alternative using this guidance: \(guidance). Preserve the intended meaning of this draft: \(currentDraft)"
        draft = await store.draftReply(to: message, instruction: rewriteInstruction)
        isGenerating = false
    }

    private func redictateDraft() async {
        draft = ""
        instruction = ""
        do {
            try await speech.start()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
            Button { showingFileImporter = true } label: {
                HStack {
                    LucideIcon(name: "paperclip", size: 18)
                    Text(attachments.isEmpty ? "Add attachments" : "Add another attachment")
                    Spacer()
                    if !attachments.isEmpty {
                        Text(attachments.count, format: .number).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: InboxDesign.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            ForEach(attachments) { attachment in
                HStack {
                    LucideIcon(name: "file-text", size: 18).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(attachment.filename).font(InboxDesign.Typography.font(.subheadline)).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                            .font(InboxDesign.Typography.font(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        attachments.removeAll { $0.id == attachment.id }
                    } label: {
                        LucideIcon(name: "circle-x", size: 19)
                    }
                    .accessibilityLabel("Remove \(attachment.filename)")
                }
                .padding(InboxDesign.Spacing.small)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: InboxDesign.Radius.compact))
            }
        }
        .padding(.horizontal, InboxDesign.Spacing.medium)
        .padding(.vertical, InboxDesign.Spacing.small)
        .inboxSurface(radius: InboxDesign.Radius.control, material: .ultraThinMaterial)
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                let size = values.fileSize ?? 0
                guard size <= 20 * 1024 * 1024 else { throw AttachmentError.tooLarge(url.lastPathComponent) }
                attachments.append(.init(filename: url.lastPathComponent, mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream", data: try Data(contentsOf: url)))
            }
        } catch { self.error = error.localizedDescription }
    }

    private func toggleDictation() async {
        if speech.isRecording {
            speech.stop()
            InteractionFeedback.shared.perform(.ready, sound: false)
            await generate(playSounds: false)
        } else {
            InteractionFeedback.shared.perform(.beginWork, sound: false)
            do { try await speech.start() }
            catch {
                self.error = error.localizedDescription
                InteractionFeedback.shared.perform(.error, sound: false)
            }
        }
    }

    private func generate(playSounds: Bool = true) async {
        guard !instruction.isEmpty else { return }
        InteractionFeedback.shared.perform(.beginWork, sound: playSounds)
        isGenerating = true
        draft = await store.draftReply(to: message, instruction: instruction)
        isGenerating = false
        InteractionFeedback.shared.perform(.ready, sound: playSounds)
    }

    private func send() async {
        isSending = true
        do {
            switch mode {
            case .reply:
                try await store.sendReply(to: message, body: draft, attachments: attachments)
            case .replyAll:
                try await store.sendReplyAll(to: message, body: draft, attachments: attachments)
            case .forward:
                try await store.forward(message, to: normalizedRecipient, body: draft, attachments: attachments)
            }
            InteractionFeedback.shared.perform(.success)
            dismiss()
        }
        catch {
            self.error = error.localizedDescription
            isSending = false
            InteractionFeedback.shared.perform(.error)
        }
    }

    private var normalizedRecipient: String {
        recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recipientIsValid: Bool {
        let parts = normalizedRecipient.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}

private struct EmptyQueueShimmerText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        if reduceMotion {
            label
                .foregroundStyle(.secondary.opacity(0.72))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let duration = 3.4
                let progress = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: duration) / duration

                label
                    .foregroundStyle(.secondary.opacity(0.38))
                    .overlay {
                        GeometryReader { geometry in
                            let width = max(geometry.size.width, 1)

                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: Color.primary.opacity(0.10), location: 0.22),
                                    .init(color: Color.primary.opacity(0.58), location: 0.50),
                                    .init(color: Color.primary.opacity(0.10), location: 0.78),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: width * 1.35)
                            .offset(x: -width * 1.35 + CGFloat(progress) * width * 2.7)
                        }
                        .mask { label }
                        .allowsHitTesting(false)
                    }
            }
        }
    }

    private var label: some View {
        Text(title)
            .font(InboxDesign.Typography.font(.title3, weight: .semibold))
    }
}

private enum AttachmentError: LocalizedError {
    case tooLarge(String)
    var errorDescription: String? {
        switch self { case .tooLarge(let name): "\(name) is larger than the 20 MB attachment limit." }
    }
}
