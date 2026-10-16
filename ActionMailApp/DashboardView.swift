import AppKit
import SwiftUI

struct DashboardView: View {
    @Bindable var store: WorkflowStore
    var onExpand: () -> Void = {}
    @State private var selection: WorkflowState = .action
    @State private var currentIndex = 0
    @State private var pendingQueueSelection: Task<Void, Never>?
    @State private var showingArchive = false
    @State private var trafficLightsHovered = false
    @AppStorage("inboxZeroMonochrome") private var monochromeMode = false

    private var messages: [WaitingThread] {
        store.threads
            .filter { $0.state == selection && !$0.isArchived }
            .sorted { $0.sentAt > $1.sentAt }
    }

    private var currentMessage: WaitingThread? {
        guard messages.indices.contains(currentIndex) else { return nil }
        return messages[currentIndex]
    }

    var body: some View {
        VStack(spacing: 12) {
            topBar

            HStack(spacing: 10) {
                messageCard
                countCard
            }
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }

            queueBar
            connectionStatus
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .grayscale(monochromeMode ? 1 : 0)
        .contextMenu {
            Toggle(isOn: $monochromeMode) {
                Label("Monochrome", systemImage: "circle.lefthalf.filled")
            }
            Divider()
            Text("Appearance")
        }
        .onChange(of: selection) { _, _ in currentIndex = 0 }
        .onChange(of: messages.count) { _, count in
            currentIndex = min(currentIndex, max(0, count - 1))
        }
        .sheet(isPresented: $showingArchive) {
            ArchiveView(store: store)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                store.performDailyHousekeepingIfNeeded()
                guard !Task.isCancelled, automaticScanIsDue else { continue }
                guard !mailIsFrontmost else {
                    store.statusMessage = "Background sync paused while Mail is active"
                    continue
                }
                await store.scanMail()
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            ZStack {
                Color.clear
                    .contentShape(Rectangle())

                trafficLights
                    .opacity(trafficLightsHovered ? 1 : 0)
                    .allowsHitTesting(trafficLightsHovered)
                    .accessibilityHidden(!trafficLightsHovered)
            }
            .frame(width: 77, height: 21)
            .onHover { isHovering in
                withAnimation(.easeOut(duration: isHovering ? 0.16 : 0.24)) {
                    trafficLightsHovered = isHovering
                }
            }
                .padding(.leading, 14)

            Spacer(minLength: 12)

            ShimmeringBrandName()
                .frame(width: 142, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 21)
    }

    private var messageCard: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(accentColor.gradient)

            if let message = currentMessage {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.fill")
                        Text("EMAIL HEADER")
                    }
                    .font(.caption2.weight(.semibold))
                    .opacity(0.72)

                    Text(message.subject)
                        .font(.title2.weight(.semibold))
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)

                    Text(message.recipient)
                        .font(.callout)
                        .lineLimit(1)
                        .opacity(0.78)

                    Spacer(minLength: 4)

                    HStack(spacing: 7) {
                        Image(systemName: "chevron.up")
                        Text("Swipe to browse")
                        Image(systemName: "chevron.down")
                        Spacer()
                        Text("\(currentIndex + 1) / \(messages.count)")
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                    .opacity(0.72)
                }
                .foregroundStyle(.white)
                .padding(18)
                .id(message.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            } else {
                ContentUnavailableView {
                    Label("No \(selection.rawValue) mail", systemImage: symbol(for: selection))
                } description: {
                    Text("This queue is clear")
                }
                .foregroundStyle(.white)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            MailCardSwipeView(
                onSwipeUp: showNext,
                onSwipeDown: showPrevious,
                onClick: {},
                onDoubleClick: activateMail
            )
        }
        .contextMenu {
            if let message = currentMessage {
                ForEach(WorkflowState.allCases.filter { $0 != message.state }) { state in
                    Button("Move to \(state.rawValue)") {
                        moveCurrentMessage(to: state)
                    }
                }
            }
        }
    }

    private var countCard: some View {
        VStack(spacing: 2) {
            HStack {
                Spacer()
                Circle()
                    .fill(accentColor)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: symbol(for: selection))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
            }

            Spacer(minLength: 0)

            Text(messages.count, format: .number)
                .font(.system(size: 66, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text(selection.rawValue.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    Task { await store.scanMail() }
                } label: {
                    Label(store.isScanning ? "Scanning" : "Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .disabled(store.isScanning)

                Button {
                    showingArchive = true
                } label: {
                    Label("\(store.archivedThreads.count)", systemImage: "archivebox")
                        .font(.caption)
                        .monospacedDigit()
                }
                .help("Open Archive")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 142)
        .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var queueBar: some View {
        HStack(spacing: 6) {
            ForEach(WorkflowState.allCases) { state in
                VStack(spacing: 5) {
                    Image(systemName: symbol(for: state))
                        .font(.system(size: 18, weight: .semibold))
                    Text(state.rawValue)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 58)
                .contentShape(Rectangle())
                .foregroundStyle(selection == state ? Color.white : Color.secondary)
                .background {
                    if selection == state {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(color(for: state).gradient)
                    }
                }
                .onTapGesture(count: 2) {
                    pendingQueueSelection?.cancel()
                    moveCurrentMessage(to: state)
                }
                .onTapGesture {
                    scheduleQueueSelection(state)
                }
                .contextMenu {
                    Button("View \(state.rawValue)") {
                        selectQueue(state)
                    }
                    if currentMessage?.state != state {
                        Button("Move current email to \(state.rawValue)") {
                            moveCurrentMessage(to: state)
                        }
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(state.rawValue), \(store.counts(for: state)) messages")
                .accessibilityHint("Click to view. Double-click to move the current email here.")
                .help("Click to view \(state.rawValue). Double-click to move current email here.")
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
    }

    private var trafficLights: some View {
        HStack(spacing: 7) {
            windowControl(color: Color(red: 1, green: 0.37, blue: 0.34), symbol: "xmark", label: "Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            windowControl(color: Color(red: 1, green: 0.74, blue: 0.18), symbol: "minus", label: "Minimize") {
                NSApp.keyWindow?.miniaturize(nil)
            }
            windowControl(color: Color(red: 0.16, green: 0.78, blue: 0.25), symbol: "arrow.up.left.and.arrow.down.right", label: "Zoom") {
                NSApp.keyWindow?.zoom(nil)
            }
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectionColor)
                .frame(width: 13, height: 13)
                .overlay {
                    Image(systemName: connectionSymbol)
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.black.opacity(0.58))
                }

            Text(connectionMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mail connection: \(connectionMessage)")
        .help(store.statusMessage)
    }

    private var connectionMessage: String {
        if store.isScanning { return "Connecting to Mail…" }
        return store.statusMessage
    }

    private var connectionColor: Color {
        if store.isScanning { return Color(red: 1, green: 0.74, blue: 0.18) }
        if syncIsPaused { return Color(red: 1, green: 0.74, blue: 0.18) }
        if store.lastScanAt != nil { return Color(red: 0.16, green: 0.78, blue: 0.25) }
        if store.statusMessage == "Ready to connect to Mail" { return .secondary }
        return Color(red: 1, green: 0.37, blue: 0.34)
    }

    private var connectionSymbol: String {
        if store.isScanning { return "ellipsis" }
        if syncIsPaused { return "pause.fill" }
        if store.lastScanAt != nil { return "checkmark" }
        if store.statusMessage == "Ready to connect to Mail" { return "minus" }
        return "xmark"
    }

    private var syncIsPaused: Bool {
        store.statusMessage == "Background sync paused while Mail is active"
    }

    private var mailIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail"
    }

    private var automaticScanIsDue: Bool {
        guard let lastScanAt = store.lastScanAt else { return true }
        return Date.now.timeIntervalSince(lastScanAt) >= 15 * 60
    }

    private func windowControl(
        color: Color,
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.black.opacity(0.58))
                }
                .frame(width: 21, height: 21)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var accentColor: Color { color(for: selection) }

    private func scheduleQueueSelection(_ state: WorkflowState) {
        pendingQueueSelection?.cancel()
        pendingQueueSelection = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            selectQueue(state)
        }
    }

    private func selectQueue(_ state: WorkflowState) {
        withAnimation(.snappy(duration: 0.28)) {
            selection = state
        }
    }

    private func moveCurrentMessage(to state: WorkflowState) {
        pendingQueueSelection?.cancel()
        guard let message = currentMessage, message.state != state else { return }
        withAnimation(.snappy(duration: 0.28)) {
            store.move(message, to: state)
        }
    }

    private func showNext() {
        guard currentIndex + 1 < messages.count else { return }
        withAnimation(.snappy(duration: 0.3)) { currentIndex += 1 }
    }

    private func showPrevious() {
        guard currentIndex > 0 else { return }
        withAnimation(.snappy(duration: 0.3)) { currentIndex -= 1 }
    }

    private func symbol(for state: WorkflowState) -> String {
        switch state {
        case .action: "bolt.fill"
        case .waiting: "hourglass"
        case .readLater: "bookmark.fill"
        case .done: "checkmark"
        }
    }

    private func color(for state: WorkflowState) -> Color {
        switch state {
        case .action: .red
        case .waiting: .orange
        case .readLater: .blue
        case .done: .green
        }
    }

    private func openMail() {
        guard let messageID = currentMessage?.outboundMessageID
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !messageID.isEmpty else {
            activateMail()
            return
        }

        let bareID = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let wrappedID = "<\(bareID)>"
        let safeCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))

        guard let encodedID = wrappedID.addingPercentEncoding(withAllowedCharacters: safeCharacters),
              let messageURL = URL(string: "message://\(encodedID)") else {
            activateMail()
            return
        }

        NSWorkspace.shared.open(messageURL)
    }

    private func activateMail() {
        if let runningMail = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.mail"
        ).first {
            runningMail.activate(options: [.activateAllWindows])
            return
        }

        guard let mailURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.mail"
        ) else { return }

        NSWorkspace.shared.openApplication(
            at: mailURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

private struct ShimmeringBrandName: View {
    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        Text("inbox.Zer0")
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(.gray.opacity(0.78))
            .overlay {
                LinearGradient(
                    colors: [.clear, .white.opacity(0.72), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .rotationEffect(.degrees(12))
                .offset(x: shimmerOffset * 120)
                .mask {
                    Text("inbox.Zer0")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                }
            }
            .task {
                while !Task.isCancelled {
                    var reset = Transaction()
                    reset.disablesAnimations = true
                    withTransaction(reset) { shimmerOffset = -1 }
                    withAnimation(.linear(duration: 1.1)) { shimmerOffset = 1 }
                    try? await Task.sleep(for: .seconds(6.5))
                }
            }
            .accessibilityLabel("inbox dot zero")
            .help("inbox.Zer0")
    }
}

private struct ArchiveView: View {
    @Bindable var store: WorkflowStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Archive", systemImage: "archivebox.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }

            if store.archivedThreads.isEmpty {
                ContentUnavailableView(
                    "Archive is empty",
                    systemImage: "archivebox",
                    description: Text("Completed emails move here after seven days.")
                )
            } else {
                List(store.archivedThreads) { thread in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.subject)
                                .font(.headline)
                                .lineLimit(1)
                            Text(thread.recipient)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(thread.completedAt ?? thread.sentAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button("Restore") {
                            store.restore(thread)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 340)
    }
}

private struct MailCardSwipeView: NSViewRepresentable {
    let onSwipeUp: () -> Void
    let onSwipeDown: () -> Void
    let onClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> MailCardSwipeNSView {
        let view = MailCardSwipeNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: MailCardSwipeNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: MailCardSwipeNSView) {
        view.onSwipeUp = onSwipeUp
        view.onSwipeDown = onSwipeDown
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
    }
}

private final class MailCardSwipeNSView: NSView {
    var onSwipeUp: (() -> Void)?
    var onSwipeDown: (() -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var accumulatedScroll: CGFloat = 0
    private var didTriggerSwipe = false
    private var mouseDownPoint: NSPoint?

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began {
            accumulatedScroll = 0
            didTriggerSwipe = false
        }

        let directionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        accumulatedScroll += event.scrollingDeltaY * directionMultiplier

        if !didTriggerSwipe, abs(accumulatedScroll) >= 18 {
            didTriggerSwipe = true
            accumulatedScroll > 0 ? onSwipeUp?() : onSwipeDown?()
        }

        if event.phase == .ended || event.phase == .cancelled {
            accumulatedScroll = 0
            didTriggerSwipe = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            mouseDownPoint = nil
        } else {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        mouseDownPoint = nil
        let end = convert(event.locationInWindow, from: nil)
        let verticalDistance = end.y - start.y
        if abs(verticalDistance) >= 24 {
            verticalDistance > 0 ? onSwipeUp?() : onSwipeDown?()
        } else {
            onClick?()
        }
    }
}
