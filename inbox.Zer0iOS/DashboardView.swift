import LucideIcons
import SwiftUI
import UIKit

struct DashboardView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var store: InboxStore
    @State private var selectedRoute: QueueRoute?
    @State private var hasSeenOutstandingWork = false
    @State private var celebratedThisSession = false
    @AppStorage("inboxZeroMonochrome") private var monochrome = false

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: InboxDesign.Spacing.medium),
            GridItem(.flexible(), spacing: InboxDesign.Spacing.medium)
        ]
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                    header
                    if store.messages.isEmpty && (!store.hasCompletedInitialLoad || store.isSyncing) {
                        recoveryStatus
                    }
                    Group {
                        if isZeroMoment {
                            zeroMoment
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        } else {
                            queueGrid
                                .transition(.opacity.combined(with: .scale(scale: 0.99)))
                        }
                    }
                    if !focusMessages.isEmpty {
                        focusSection
                    }
                }
                .padding(.horizontal, InboxDesign.Spacing.large)
                .padding(.top, InboxDesign.Spacing.xLarge)
                .padding(.bottom, InboxDesign.Spacing.xLarge * 3)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
            .refreshable {
                await refreshDashboard()
            }
        }
        .navigationDestination(item: $selectedRoute) { route in
            MessageStackView(store: store, queue: route.queue, initialMessageID: route.messageID)
        }
        .onAppear {
            hasSeenOutstandingWork = outstandingCount > 0
#if DEBUG
            openRequestedPreviewQueue()
#endif
        }
#if DEBUG
        .onChange(of: store.messages.count) { _, _ in
            openRequestedPreviewQueue()
        }
#endif
        .onChange(of: outstandingCount) { oldValue, newValue in
            if newValue > 0 {
                hasSeenOutstandingWork = true
                celebratedThisSession = false
            } else if oldValue > 0,
                      hasSeenOutstandingWork,
                      !celebratedThisSession,
                      store.hasCompletedInitialLoad {
                celebratedThisSession = true
                InteractionFeedback.shared.perform(.settled)
            }
        }
        .animation(.smooth(duration: 0.5), value: isZeroMoment)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func refreshDashboard() async {
        async let mailRefresh: Void = store.sync()
        async let contextRefresh: Void = store.dailyContext.refresh()
        _ = await (mailRefresh, contextRefresh)
    }

#if DEBUG
    private func openRequestedPreviewQueue() {
        guard selectedRoute == nil else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let queue: InboxQueue?
        if arguments.contains("-OpenActionQueue") {
            queue = .action
        } else if arguments.contains("-OpenWaitingQueue") {
            queue = .waiting
        } else if arguments.contains("-OpenReadLaterQueue") {
            queue = .readLater
        } else if arguments.contains("-OpenDoneQueue") {
            queue = .done
        } else {
            queue = nil
        }
        guard let queue else { return }
        let opensList = arguments.contains("-OpenQueueList")
        selectedRoute = QueueRoute(
            queue: queue,
            messageID: opensList ? nil : store.messages.first(where: { $0.queue == queue })?.id
        )
    }
#endif

    private var header: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                ShimmeringInboxBrand()
                Spacer()
            }
            .padding(.horizontal, InboxDesign.Spacing.small)
            dailyBriefing
        }
    }

    private var dailyBriefing: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
            Text(briefingDateTitle)
                .font(InboxDesign.Typography.metadata)
                .foregroundStyle(.primary)
                .lineLimit(1)

            briefingParagraph
                .font(InboxDesign.Typography.briefing)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAction(named: "Open Calendar") {
                    if store.dailyContext.calendarConnected { openCalendar() }
                }
        }
        .padding(.horizontal, InboxDesign.Spacing.xLarge)
        .padding(.vertical, InboxDesign.Spacing.large)
        .frame(maxWidth: .infinity, minHeight: 248, alignment: .leading)
        .inboxContentSurface(radius: InboxDesign.Radius.feature)
        .accessibilityElement(children: .combine)
    }

    private var recoveryStatus: some View {
        HStack(spacing: InboxDesign.Spacing.medium) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Restoring your mail")
                    .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                Text("Messages will appear here as your mail accounts finish syncing.")
                    .font(InboxDesign.Typography.font(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(InboxDesign.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inboxContentSurface(radius: InboxDesign.Radius.control)
        .accessibilityElement(children: .combine)
    }

    private var briefingParagraph: Text {
        let overviewText = Color.primary
        var result = Text("\(greeting). ").foregroundColor(overviewText)
            + Text("You have ").foregroundColor(overviewText)

        var metrics: [Text] = []
        if store.dailyContext.calendarConnected {
            let count = store.dailyContext.calendarEventCount
            metrics.append(
                Text("\(count) \(count == 1 ? "calendar event" : "calendar events") ").foregroundColor(overviewText)
                + inlineIcon("calendar-days", color: monochrome ? .label : .systemRed)
            )
        }
        let actionCount = store.count(in: .action)
        metrics.append(
            Text("\(actionCount) \(actionCount == 1 ? "email action" : "email actions") ").foregroundColor(overviewText)
            + inlineIcon(InboxQueue.action.icon, color: monochrome ? .label : UIColor(InboxQueue.action.color))
        )

        for index in metrics.indices {
            if index > 0 {
                result = result + Text(index == metrics.count - 1 ? " and " : ", ").foregroundColor(overviewText)
            }
            result = result + metrics[index]
        }
        result = result + Text(" today. ").foregroundColor(overviewText)

        if let freeTime = store.dailyContext.calendarFreeTimeSummary {
            if freeTime.hasPrefix("You’re ") {
                result = result
                    + Text("You’re ").foregroundColor(overviewText)
                    + Text(String(freeTime.dropFirst("You’re ".count))).foregroundColor(overviewText)
            } else {
                result = result + Text(freeTime).foregroundColor(overviewText)
            }
        }
        return result
    }

    private func inlineIcon(_ name: String, color: UIColor) -> Text {
        guard let source = UIImage(lucideId: name) else { return Text("") }
        let size = CGSize(width: 18, height: 18)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.withTintColor(color, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: size))
        }
        return Text(Image(uiImage: image))
    }

    private func openCalendar() {
        let interval = Date.now.timeIntervalSinceReferenceDate
        if let url = URL(string: "calshow:\(interval)") {
            openURL(url)
        }
    }

    private var briefingDateTitle: String {
        let date = Date.now
        let day = Calendar.current.component(.day, from: date)
        let suffix: String
        if (11...13).contains(day % 100) {
            suffix = "th"
        } else {
            suffix = switch day % 10 {
            case 1: "st"
            case 2: "nd"
            case 3: "rd"
            default: "th"
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMM"
        let prefix = formatter.string(from: date)
        return "\(prefix) \(day)\(suffix)"
    }

    private var queueGrid: some View {
        LazyVGrid(columns: columns, spacing: InboxDesign.Spacing.medium) {
            ForEach(InboxQueue.allCases) { queue in
                Button { selectedRoute = QueueRoute(queue: queue) } label: {
                    VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                        HStack {
                            LucideIcon(name: queue.icon, size: 19)
                            Spacer()
                            Text(store.count(in: queue), format: .number)
                                .font(InboxDesign.Typography.queueCount)
                                .monospacedDigit()
                        }
                        Text(queue.rawValue)
                            .font(InboxDesign.Typography.queueLabel)
                    }
                    .foregroundStyle(monochrome ? Color.primary : Color.white)
                    .padding(InboxDesign.Spacing.large)
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: InboxDesign.Radius.card, style: .continuous)
                            .fill(monochrome ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(queue.color.gradient))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: InboxDesign.Radius.card)
                            .stroke(monochrome ? Color.primary.opacity(0.1) : Color.white.opacity(0.55))
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint("Opens the focused \(queue.rawValue) stack")
            }
        }
    }

    private var zeroMoment: some View {
        Button {
            selectedRoute = QueueRoute(queue: .done)
        } label: {
            VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                HStack(alignment: .top) {
                    Image("ZeroLogo")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                    Spacer()
                    Label("Clear", systemImage: "checkmark")
                        .font(InboxDesign.Typography.font(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
                    Text("Everything is handled.")
                        .font(InboxDesign.Typography.section)
                    Text("Action, Waiting, and Read Later are clear. Enjoy the quiet.")
                        .font(InboxDesign.Typography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: InboxDesign.Spacing.small) {
                        clearedQueueLabels
                    }
                    VStack(alignment: .leading, spacing: InboxDesign.Spacing.xSmall) {
                        clearedQueueLabels
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .foregroundStyle(.primary)
            .padding(InboxDesign.Spacing.xLarge)
            .frame(maxWidth: .infinity, minHeight: 224, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: InboxDesign.Radius.feature, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                InboxDesign.SurfaceLevel.elevated300.color,
                                InboxDesign.SurfaceLevel.raised200.color
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: InboxDesign.Radius.feature, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Everything is handled. Action, Waiting, and Read Later are clear.")
        .accessibilityHint("Opens completed messages")
    }

    private var focusSection: some View {
        LazyVStack(alignment: .leading, spacing: InboxDesign.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today’s focus")
                    .font(InboxDesign.Typography.section)
                Spacer()
                if !focusMessages.isEmpty {
                    Text("\(focusMessages.count)")
                        .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(focusMessages) { message in
                Button { selectedRoute = QueueRoute(queue: .action, messageID: message.id) } label: {
                    HStack(spacing: InboxDesign.Spacing.small) {
                        SenderMark(message: message, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.subject)
                                .font(InboxDesign.Typography.itemTitle)
                                .lineLimit(1)
                            Text(message.displaySummary ?? message.snippet.htmlEntityDecoded)
                                .font(InboxDesign.Typography.itemDetail)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        LucideIcon(name: "chevron-right", size: 16).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, InboxDesign.Spacing.xSmall)
                    .frame(minHeight: 56)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var focusMessages: [InboxMessage] {
        store.messages(in: .action)
    }

    @ViewBuilder
    private var clearedQueueLabels: some View {
        ForEach([InboxQueue.action, .waiting, .readLater]) { queue in
            Label(queue.rawValue, systemImage: "checkmark")
                .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var outstandingCount: Int {
        store.count(in: .action) + store.count(in: .waiting) + store.count(in: .readLater)
    }

    private var isZeroMoment: Bool {
        hasConnectedMailbox &&
            store.hasCompletedInitialLoad &&
            !store.isSyncing &&
            outstandingCount == 0
    }

    private var hasConnectedMailbox: Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MockZeroMoment") { return true }
#endif
        return store.gmail.hasCredentials
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return hour < 12 ? "Good Morning" : hour < 18 ? "Good Afternoon" : "Good Evening"
    }
}

private struct QueueRoute: Hashable {
    let queue: InboxQueue
    var messageID: String? = nil
}

private struct BriefingMetric: View {
    let icon: String
    let value: Int
    let label: String
    let color: Color
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle().inset(by: -10))
                    .accessibilityHint("Opens Calendar for today")
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            LucideIcon(name: icon, size: 17)
                .foregroundStyle(color)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + 4
                }
            Text(value, format: .number)
                .font(InboxDesign.Typography.font(.title2, weight: .bold).monospacedDigit())
            Text(label)
                .font(InboxDesign.Typography.font(.title2, weight: .semibold))
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

private struct BriefingAvailability: View {
    let text: String

    var body: some View {
        if text.hasPrefix("You’re ") {
            Text("You’re")
                .font(InboxDesign.Typography.font(.title2, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(text.dropFirst("You’re ".count)))
                .font(InboxDesign.Typography.font(.title2, weight: .semibold))
                .foregroundStyle(.primary)
        } else {
            Text(text)
                .font(InboxDesign.Typography.font(.title2, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

private struct BriefingSentenceLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let available = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > available {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += (x == 0 ? 0 : spacing) + size.width
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x)
        }
        return CGSize(width: min(available, usedWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            if x > bounds.minX { x += spacing }
            subview.place(at: CGPoint(x: x, y: y + (max(rowHeight, size.height) - size.height) / 2), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct AtmosphereBackground: View {
    @AppStorage("inboxZeroAtmosphereStyle") private var atmosphereStyle = "blue"
    @AppStorage("inboxZeroMonochrome") private var monochrome = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            InboxDesign.SurfaceLevel.background100.color
            if atmosphereStyle == "pearl" {
                pearlAtmosphere
                    .transition(.opacity)
            } else if atmosphereStyle == "slateHaze" {
                slateHazeAtmosphere
                    .transition(.opacity)
            } else if atmosphereStyle != "off" {
                RadialGradient(
                    colors: [
                        atmosphereColor.opacity(primaryOpacity),
                        atmosphereColor.opacity(secondaryOpacity),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.52, y: 0.44),
                    startRadius: 24,
                    endRadius: 520
                )
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.28), value: atmosphereStyle)
        .animation(.easeInOut(duration: 0.28), value: monochrome)
        .onAppear {
            // Preserve existing installs while retiring the Black & White atmosphere.
            if atmosphereStyle == "blackWhite" {
                atmosphereStyle = "pearl"
            }
        }
    }

    private var pearlAtmosphere: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.065, green: 0.060, blue: 0.085), Color(red: 0.070, green: 0.075, blue: 0.105)]
                    : [Color(red: 0.985, green: 0.978, blue: 0.994), Color(red: 0.944, green: 0.965, blue: 0.995)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(colorScheme == .dark ? 0.56 : 0.54)

            RadialGradient(
                colors: [pearlLavender.opacity(pearlOpacity(0.22)), .clear],
                center: UnitPoint(x: 0.30, y: 0.26),
                startRadius: 18,
                endRadius: 410
            )

            RadialGradient(
                colors: [pearlBlue.opacity(pearlOpacity(0.20)), .clear],
                center: UnitPoint(x: 0.62, y: 0.48),
                startRadius: 24,
                endRadius: 470
            )

            RadialGradient(
                colors: [pearlBlush.opacity(pearlOpacity(0.16)), .clear],
                center: UnitPoint(x: 0.78, y: 0.76),
                startRadius: 18,
                endRadius: 390
            )

            LinearGradient(
                colors: [Color.white.opacity(colorScheme == .dark ? 0.018 : 0.28), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .blur(radius: 34)
        .scaleEffect(1.08)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var slateHazeAtmosphere: some View {
        ZStack {
            Color(
                red: colorScheme == .dark ? 0.09 : 0.83,
                green: colorScheme == .dark ? 0.10 : 0.82,
                blue: colorScheme == .dark ? 0.12 : 0.79
            )

            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.15, green: 0.16, blue: 0.17), Color(red: 0.18, green: 0.23, blue: 0.29), Color(red: 0.09, green: 0.10, blue: 0.12)]
                    : [Color(red: 0.85, green: 0.82, blue: 0.77), Color(red: 0.62, green: 0.68, blue: 0.73), Color(red: 0.42, green: 0.50, blue: 0.59)],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(colorScheme == .dark ? 0.46 : 0.74)

            RadialGradient(
                colors: [
                    Color(red: 0.48, green: 0.57, blue: 0.66).opacity(colorScheme == .dark ? 0.34 : 0.72),
                    Color(red: 0.58, green: 0.64, blue: 0.69).opacity(colorScheme == .dark ? 0.14 : 0.34),
                    .clear
                ],
                center: UnitPoint(x: 0.50, y: 0.52),
                startRadius: 30,
                endRadius: 540
            )

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.025 : 0.22),
                    .clear,
                    Color.black.opacity(colorScheme == .dark ? 0.16 : 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .blur(radius: 24)
        .scaleEffect(1.10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var pearlLavender: Color { Color(red: 0.72, green: 0.69, blue: 0.91) }
    private var pearlBlue: Color { Color(red: 0.58, green: 0.78, blue: 0.97) }
    private var pearlBlush: Color { Color(red: 0.94, green: 0.73, blue: 0.82) }

    private func pearlOpacity(_ lightValue: Double) -> Double {
        colorScheme == .dark ? lightValue * 0.46 : lightValue
    }

    private var usesBlackAndWhite: Bool {
        monochrome
    }

    private var atmosphereColor: Color {
        usesBlackAndWhite ? Color.primary : Color(red: 0.43, green: 0.70, blue: 1.0)
    }

    private var primaryOpacity: Double {
        if usesBlackAndWhite { return colorScheme == .dark ? 0.10 : 0.065 }
        return colorScheme == .dark ? 0.12 : 0.20
    }

    private var secondaryOpacity: Double {
        if usesBlackAndWhite { return colorScheme == .dark ? 0.035 : 0.022 }
        return colorScheme == .dark ? 0.045 : 0.08
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .brightness(configuration.isPressed ? -0.018 : 0)
            .hoverEffect(.highlight)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct SenderMark: View {
    let message: InboxMessage
    var size: CGFloat = 44
    @AppStorage("inboxZeroMonochrome") private var monochrome = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.systemBackground).opacity(0.94))

            BrandLogoImage(message: message, size: size, monochrome: monochrome) {
                senderInitial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.primary.opacity(monochrome ? 0.16 : 0.09), lineWidth: 1)
        }
        .overlay {
            if message.accountEmail != nil {
                Circle()
                    .strokeBorder(
                        monochrome ? Color.primary.opacity(0.52) : MailboxPersona.color(for: message.accountEmail),
                        style: StrokeStyle(lineWidth: monochrome ? 1.5 : 2.5, dash: monochrome ? [3, 2] : [])
                    )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if message.showsBrandCheck {
                VerifiedBrandBadge(size: max(13, size * 0.34), monochrome: monochrome)
                    .offset(x: size * 0.02, y: size * 0.02)
            }
        }
        .animation(.snappy(duration: 0.2), value: monochrome)
    }

    private var senderInitial: some View {
        Text(message.senderName.prefix(1))
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
    }
}

private struct VerifiedBrandBadge: View {
    let size: CGFloat
    let monochrome: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(monochrome ? Color.primary : Color.blue)
            Circle()
                .strokeBorder(Color(.systemBackground), lineWidth: 2)
            LucideIcon(name: "check", size: size * 0.55)
                .foregroundStyle(Color(.systemBackground))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Verified sender")
    }
}

private enum BrandLogo {
    static func urls(for message: InboxMessage) -> [URL] {
        // No third-party logo lookup or remote sender image fetch by default.
        // A future opt-in implementation should explain the associated data sharing.
        []
    }

}

private struct BrandLogoImage<Fallback: View>: View {
    let message: InboxMessage
    let size: CGFloat
    let monochrome: Bool
    @ViewBuilder let fallback: () -> Fallback
    @State private var logo: UIImage?

    var body: some View {
        Group {
            if RecognizedBrand.domain(from: message.senderAddress) == "microsoft.com" {
                MicrosoftBrandMark(size: size, monochrome: monochrome)
            } else if let logo {
                let ratio = logo.size.width / max(logo.size.height, 1)
                let isTile = (0.78...1.28).contains(ratio)
                Image(uiImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: isTile ? .fill : .fit)
                    .padding(isTile ? 0 : size * 0.11)
                    .frame(width: size, height: size)
                    .grayscale(monochrome ? 1 : 0)
                    .saturation(monochrome ? 0 : 1)
                    .clipShape(Circle())
            } else {
                fallback()
            }
        }
        .task(id: message.senderAddress) { await loadBestLogo() }
    }

    @MainActor
    private func loadBestLogo() async {
        var acceptableWordmark: UIImage?
        for url in BrandLogo.urls(for: message) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode,
                  let image = UIImage(data: data) else { continue }

            let minimumPixelDimension = min(image.size.width * image.scale, image.size.height * image.scale)
            let ratio = image.size.width / max(image.size.height, 1)
            if minimumPixelDimension >= 96, (0.78...1.28).contains(ratio) {
                logo = image
                return
            }
            if minimumPixelDimension >= 64, acceptableWordmark == nil {
                acceptableWordmark = image
            }
        }
        logo = acceptableWordmark
    }
}

private struct ShimmeringInboxBrand: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var shimmerOffset: CGFloat = -1.2

    var body: some View {
        Image("ZeroLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 40, height: 40)
            .foregroundStyle(.primary)
            .overlay {
                if !reduceMotion {
                    LinearGradient(
                        colors: [
                            .clear,
                            (colorScheme == .dark ? Color.black : Color.white).opacity(0.92),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 60)
                    .rotationEffect(.degrees(12))
                    .offset(x: shimmerOffset * 70)
                    .mask {
                        Image("ZeroLogo")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                    }
                }
            }
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    var reset = Transaction()
                    reset.disablesAnimations = true
                    withTransaction(reset) { shimmerOffset = -1.2 }
                    withAnimation(.easeInOut(duration: 2.3)) { shimmerOffset = 1.2 }
                    try? await Task.sleep(for: .seconds(5.8))
                }
            }
            .accessibilityLabel("inbox dot zero")
    }
}

private struct MicrosoftBrandMark: View {
    let size: CGFloat
    let monochrome: Bool

    private let colors = [
        Color(red: 0.949, green: 0.314, blue: 0.133),
        Color(red: 0.498, green: 0.729, blue: 0),
        Color(red: 0, green: 0.643, blue: 0.937),
        Color(red: 1, green: 0.725, blue: 0)
    ]

    var body: some View {
        let markSize = size * 0.56
        let gap = max(1.5, size * 0.035)
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed((markSize - gap) / 2), spacing: gap), count: 2),
            spacing: gap
        ) {
            ForEach(colors.indices, id: \.self) { index in
                Rectangle()
                    .fill(monochrome ? Color.primary : colors[index])
                    .frame(width: (markSize - gap) / 2, height: (markSize - gap) / 2)
            }
        }
        .frame(width: markSize, height: markSize)
        .accessibilityHidden(true)
    }
}
