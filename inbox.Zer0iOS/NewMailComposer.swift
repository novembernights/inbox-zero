import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct NewMailComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: InboxStore

    @State private var senderAccount: String
    @State private var toText = ""
    @State private var ccText = ""
    @State private var bccText = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var showsCopyFields = false
    @State private var attachments: [OutgoingAttachment] = []
    @State private var attachmentMenuExpanded: Bool
    @State private var photoSelection: PhotosPickerItem?
    @State private var importerKind: ImporterKind = .browse
    @State private var showingFileImporter = false
    @State private var showingSendConfirmation = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case to, cc, bcc, subject, body
    }

    private enum ImporterKind {
        case document, browse

        var contentTypes: [UTType] {
            switch self {
            case .document: [.pdf, .plainText, .rtf, .data]
            case .browse: [.item]
            }
        }
    }

    init(store: InboxStore, initialAccount: String? = nil) {
        self.store = store
        _senderAccount = State(initialValue: initialAccount ?? store.accountEmail ?? store.accountEmails.first ?? "")
        _attachmentMenuExpanded = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("-OpenAttachmentMenu")
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InboxDesign.Spacing.large) {
                    addressingCard
                    messageCard

                    if !attachments.isEmpty {
                        attachmentsCard
                            .id("compose-attachments")
                    }

                    if let errorMessage {
                        HStack(alignment: .top, spacing: InboxDesign.Spacing.small) {
                            LucideIcon(name: "triangle-alert", size: 17)
                            Text(errorMessage)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(InboxDesign.Typography.font(.caption, weight: .medium))
                        .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, InboxDesign.Spacing.large)
                .padding(.top, InboxDesign.Spacing.medium)
                .padding(.bottom, attachmentMenuExpanded ? 190 : InboxDesign.Spacing.xLarge)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AtmosphereBackground())
            .navigationTitle("New Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sendBar
            }
            .overlay(alignment: .bottomTrailing) {
                MailContextActionMenu(
                    context: .newEmail,
                    isExpanded: $attachmentMenuExpanded,
                    photoSelection: $photoSelection,
                    chooseDocument: {
                        importerKind = .document
                        showingFileImporter = true
                    },
                    browseFiles: {
                        importerKind = .browse
                        showingFileImporter = true
                    }
                )
                .padding(.trailing, InboxDesign.Spacing.large)
                .padding(.bottom, InboxDesign.floatingTabBarClearance)
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: importerKind.contentTypes,
                allowsMultipleSelection: true,
                onCompletion: importFiles
            )
            .onChange(of: photoSelection) { _, item in
                guard let item else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                    attachmentMenuExpanded = false
                }
                Task { await importPhoto(item) }
            }
            .onChange(of: store.accountEmails) { _, accounts in
                guard senderAccount.isEmpty, let first = accounts.first else { return }
                senderAccount = first
            }
            .confirmationDialog(
                "Send this email?",
                isPresented: $showingSendConfirmation,
                titleVisibility: .visible
            ) {
                Button("Send") { Task { await send() } }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("From \(MailboxPersona.name(for: senderAccount)) to \(toAddresses.joined(separator: ", ")).")
            }
            .interactiveDismissDisabled(isSending)
        }
    }

    private var addressingCard: some View {
        VStack(spacing: 0) {
            if store.accountEmails.isEmpty {
                HStack(alignment: .top, spacing: InboxDesign.Spacing.medium) {
                    LucideIcon(name: "mail-x", size: 20)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connect a mailbox first")
                            .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                        Text("Add Gmail or iCloud Mail in Settings before sending.")
                            .font(InboxDesign.Typography.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(InboxDesign.Spacing.medium)
            } else {
                addressRow(label: "From") {
                    Menu {
                        ForEach(store.accountEmails, id: \.self) { email in
                            Button {
                                senderAccount = email
                            } label: {
                                Label(
                                    "\(MailboxPersona.name(for: email)) — \(email)",
                                    systemImage: senderAccount.caseInsensitiveCompare(email) == .orderedSame
                                        ? "checkmark"
                                        : "circle"
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: InboxDesign.Spacing.xSmall) {
                            Text(MailboxPersona.name(for: senderAccount))
                                .font(InboxDesign.Typography.font(.body, weight: .semibold))
                            Text(senderAccount)
                                .font(InboxDesign.Typography.font(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            LucideIcon(name: "chevron-down", size: 14)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: InboxDesign.minimumTouchTarget, alignment: .leading)
                    }
                }

                Divider().padding(.leading, 62)

                addressRow(label: "To") {
                    HStack(spacing: InboxDesign.Spacing.small) {
                        TextField("name@example.com", text: $toText, axis: .vertical)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...3)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .to)
                            .onSubmit { focusedField = showsCopyFields ? .cc : .subject }

                        Button(showsCopyFields ? "Hide" : "Cc/Bcc") {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                                showsCopyFields.toggle()
                            }
                        }
                        .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: InboxDesign.minimumTouchTarget)
                    }
                }

                if showsCopyFields {
                    Divider().padding(.leading, 62)
                    addressRow(label: "Cc") {
                        recipientField("Optional", text: $ccText, focus: .cc)
                    }
                    Divider().padding(.leading, 62)
                    addressRow(label: "Bcc") {
                        recipientField("Optional", text: $bccText, focus: .bcc)
                    }
                }
            }

            if !invalidAddresses.isEmpty {
                Divider().padding(.leading, 62)
                Text("Check: \(invalidAddresses.joined(separator: ", "))")
                    .font(InboxDesign.Typography.font(.caption, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InboxDesign.Spacing.medium)
                    .padding(.vertical, InboxDesign.Spacing.small)
            }
        }
        .inboxSurface(radius: InboxDesign.Radius.card, material: .ultraThinMaterial)
    }

    private var messageCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: InboxDesign.Spacing.medium) {
                Text("Subject")
                    .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)

                TextField("What’s this about?", text: $subject, axis: .vertical)
                    .font(InboxDesign.Typography.font(.body, weight: .semibold))
                    .lineLimit(1...3)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .subject)
                    .onSubmit { focusedField = .body }
            }
            .padding(InboxDesign.Spacing.medium)

            Divider().padding(.leading, 62)

            ZStack(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text("Write your message")
                        .font(InboxDesign.Typography.font(.body))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $bodyText)
                    .font(InboxDesign.Typography.font(.body))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 230)
                    .focused($focusedField, equals: .body)
            }
            .padding(InboxDesign.Spacing.medium)
        }
        .inboxSurface(radius: InboxDesign.Radius.card, material: .ultraThinMaterial)
    }

    private var attachmentsCard: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.medium) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Attachments")
                        .font(InboxDesign.Typography.font(.headline, weight: .semibold))
                    Text(attachmentDetail)
                        .font(InboxDesign.Typography.font(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView(.horizontal) {
                HStack(spacing: InboxDesign.Spacing.small) {
                    ForEach(attachments) { attachment in
                        OutgoingAttachmentPreview(attachment: attachment) {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(InboxDesign.Spacing.medium)
        .inboxSurface(radius: InboxDesign.Radius.card, material: .ultraThinMaterial)
    }

    private var sendBar: some View {
        HStack(spacing: InboxDesign.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(canSend ? "Ready to send" : sendRequirement)
                    .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                if !attachments.isEmpty {
                    Text(attachmentDetail)
                        .font(InboxDesign.Typography.font(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                focusedField = nil
                showingSendConfirmation = true
            } label: {
                ComposeSendCapsuleLabel(
                    title: isSending ? "Sending…" : "Send",
                    icon: "send-horizontal",
                    isWorking: isSending
                )
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canSend || isSending)
            .opacity(canSend ? 1 : 0.46)
            .accessibilityHint("Reviews the recipients before sending")
        }
        .padding(.horizontal, InboxDesign.Spacing.large)
        .padding(.vertical, InboxDesign.Spacing.small)
        .background(.ultraThinMaterial)
    }

    private func addressRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: InboxDesign.Spacing.medium) {
            Text(label)
                .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            content()
        }
        .padding(.horizontal, InboxDesign.Spacing.medium)
        .frame(minHeight: 56)
    }

    private func recipientField(
        _ placeholder: String,
        text: Binding<String>,
        focus: Field
    ) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(1...3)
            .submitLabel(.next)
            .focused($focusedField, equals: focus)
    }

    private var toAddresses: [String] { parsedAddresses(toText) }
    private var ccAddresses: [String] { parsedAddresses(ccText) }
    private var bccAddresses: [String] { parsedAddresses(bccText) }

    private var invalidAddresses: [String] {
        (toAddresses + ccAddresses + bccAddresses).filter { !isValidEmail($0) }
    }

    private var canSend: Bool {
        !senderAccount.isEmpty
            && !toAddresses.isEmpty
            && invalidAddresses.isEmpty
            && (!bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var sendRequirement: String {
        if senderAccount.isEmpty { return "Connect a mailbox" }
        if toAddresses.isEmpty { return "Add a recipient" }
        if !invalidAddresses.isEmpty { return "Check recipient addresses" }
        return "Write a message or attach a file"
    }

    private var attachmentDetail: String {
        guard !attachments.isEmpty else { return "Photos, documents, or files" }
        let total = attachments.reduce(0) { $0 + $1.data.count }
        return "\(attachments.count) · \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
    }

    private func parsedAddresses(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func isValidEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw AttachmentImportError.unreadable
            }
            try appendAttachment(
                filename: "Photo \(attachments.count + 1).jpg",
                mimeType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg",
                data: data
            )
            photoSelection = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.contentTypeKey])
                let data = try Data(contentsOf: url)
                try appendAttachment(
                    filename: url.lastPathComponent,
                    mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream",
                    data: data
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func appendAttachment(filename: String, mimeType: String, data: Data) throws {
        guard data.count <= 20 * 1024 * 1024 else {
            throw AttachmentImportError.tooLarge(filename)
        }
        attachments.append(.init(filename: filename, mimeType: mimeType, data: data))
        InteractionFeedback.shared.perform(.ready, sound: false)
    }

    private func send() async {
        guard canSend else { return }
        isSending = true
        errorMessage = nil
        do {
            try await store.sendNewEmail(
                fromAccount: senderAccount,
                to: toAddresses,
                cc: ccAddresses,
                bcc: bccAddresses,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                body: bodyText,
                attachments: attachments
            )
            InteractionFeedback.shared.perform(.success)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSending = false
            InteractionFeedback.shared.perform(.error)
        }
    }
}

enum MailActionContext: Equatable {
    case allMail
    case newEmail
    case reader
}

struct MailContextMoveAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void
}

struct MailContextActionMenu: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: MailActionContext
    @Binding var isExpanded: Bool
    let photoSelection: Binding<PhotosPickerItem?>?
    let compose: () -> Void
    let sync: () -> Void
    let chooseDocument: () -> Void
    let browseFiles: () -> Void
    let reply: () -> Void
    let replyAll: () -> Void
    let forward: () -> Void
    let moveActions: [MailContextMoveAction]

    init(
        context: MailActionContext,
        isExpanded: Binding<Bool>,
        photoSelection: Binding<PhotosPickerItem?>? = nil,
        compose: @escaping () -> Void = {},
        sync: @escaping () -> Void = {},
        chooseDocument: @escaping () -> Void = {},
        browseFiles: @escaping () -> Void = {},
        reply: @escaping () -> Void = {},
        replyAll: @escaping () -> Void = {},
        forward: @escaping () -> Void = {},
        moveActions: [MailContextMoveAction] = []
    ) {
        self.context = context
        _isExpanded = isExpanded
        self.photoSelection = photoSelection
        self.compose = compose
        self.sync = sync
        self.chooseDocument = chooseDocument
        self.browseFiles = browseFiles
        self.reply = reply
        self.replyAll = replyAll
        self.forward = forward
        self.moveActions = moveActions
    }

    var body: some View {
        GlassEffectContainer(spacing: InboxDesign.Spacing.small) {
            ZStack(alignment: .bottomTrailing) {
                if isExpanded {
                    expandedActions
                }

                Button {
                    InteractionFeedback.shared.perform(.selection, sound: false)
                    withAnimation(menuAnimation) { isExpanded.toggle() }
                } label: {
                    InboxGooeyCircleLabel(
                        icon: isExpanded ? "x" : "plus",
                        size: 58
                    )
                    .rotationEffect(.degrees(isExpanded && !reduceMotion ? 90 : 0))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(primaryAccessibilityLabel)
                .offset(x: context == .newEmail && isExpanded ? -64 : 0)
            }
        }
        .frame(width: 240, height: menuHeight, alignment: .bottomTrailing)
        .animation(menuAnimation, value: isExpanded)
    }

    @ViewBuilder
    private var expandedActions: some View {
        switch context {
        case .allMail:
            labelledAction(
                title: "Sync mail",
                icon: "refresh-cw",
                offset: -132,
                action: sync
            )
            labelledAction(
                title: "New email",
                icon: "pencil-line",
                offset: -66,
                action: compose
            )

        case .newEmail:
            if let photoSelection {
                PhotosPicker(selection: photoSelection, matching: .images) {
                    InboxGooeyCircleLabel(icon: "image", size: 58)
                }
                .accessibilityLabel("Choose photo")
                .offset(x: -64, y: -124)
                .transition(actionTransition)
            }

            Button(action: performChooseDocument) {
                InboxGooeyCircleLabel(icon: "file", size: 58)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Choose document")
            .offset(x: -128, y: -62)
            .transition(actionTransition)

            Button(action: performBrowseFiles) {
                InboxGooeyCircleLabel(icon: "folder", size: 58)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Browse Files")
            .offset(y: -62)
            .transition(actionTransition)

        case .reader:
            replyMenu
                .offset(y: -66)
                .transition(actionTransition)

            labelledAction(
                title: "Forward",
                icon: "forward",
                offset: -132,
                action: forward
            )

            moveMenu
                .offset(y: -198)
                .transition(actionTransition)
        }
    }

    private var replyMenu: some View {
        labelledMenu(title: "Reply", icon: "reply") {
            Button {
                closeMenu()
                reply()
            } label: {
                LucideLabel(title: "Reply", icon: "reply")
            }
            Button {
                closeMenu()
                replyAll()
            } label: {
                LucideLabel(title: "Reply All", icon: "reply-all")
            }
        }
    }

    private var moveMenu: some View {
        labelledMenu(title: "Move", icon: "move-down") {
            ForEach(moveActions) { item in
                Button(role: item.role) {
                    closeMenu()
                    item.action()
                } label: {
                    LucideLabel(title: item.title, icon: item.icon)
                }
            }
        }
    }

    private func labelledAction(
        title: String,
        icon: String,
        offset: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: InboxDesign.Spacing.small) {
            Text(title)
                .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                .padding(.horizontal, InboxDesign.Spacing.small)
                .frame(minHeight: 34)
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.07), lineWidth: 0.6)
                }

            Button {
                closeMenu()
                action()
            } label: {
                InboxGooeyCircleLabel(icon: icon, size: 54)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(title)
        }
        .offset(y: offset)
        .transition(actionTransition)
    }

    private func labelledMenu<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: InboxDesign.Spacing.small) {
            Text(title)
                .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                .padding(.horizontal, InboxDesign.Spacing.small)
                .frame(minHeight: 34)
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.07), lineWidth: 0.6)
                }

            Menu(content: content) {
                InboxGooeyCircleLabel(icon: icon, size: 54)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var primaryAccessibilityLabel: String {
        if isExpanded { return "Close actions" }
        switch context {
        case .allMail: return "Open mail actions"
        case .newEmail: return "Add attachment"
        case .reader: return "Open email actions"
        }
    }

    private var actionTransition: AnyTransition {
        .scale(scale: 0.2, anchor: .bottomTrailing).combined(with: .opacity)
    }

    private var menuHeight: CGFloat {
        context == .reader ? 266 : 200
    }

    private var menuAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72)
    }

    private func closeMenu() {
        withAnimation(menuAnimation) { isExpanded = false }
    }

    private func performChooseDocument() {
        closeMenu()
        chooseDocument()
    }

    private func performBrowseFiles() {
        closeMenu()
        browseFiles()
    }
}

private struct OutgoingAttachmentPreview: View {
    let attachment: OutgoingAttachment
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InboxDesign.Spacing.xSmall) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(width: 106, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: InboxDesign.Radius.compact, style: .continuous))

                Button(role: .destructive, action: remove) {
                    LucideIcon(name: "x", size: 13)
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 7, y: -7)
                .accessibilityLabel("Remove \(attachment.filename)")
            }

            Text(attachment.filename)
                .font(InboxDesign.Typography.font(.caption, weight: .semibold))
                .lineLimit(1)
                .frame(width: 106, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                .font(InboxDesign.Typography.font(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(InboxDesign.Spacing.small)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: InboxDesign.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var preview: some View {
        if attachment.mimeType.hasPrefix("image/"), let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.primary.opacity(0.055)
                LucideIcon(name: attachmentIcon, size: 28)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var attachmentIcon: String {
        if attachment.mimeType.contains("pdf") { return "file-text" }
        if attachment.mimeType.contains("zip") { return "file-archive" }
        if attachment.mimeType.contains("audio") { return "audio-lines" }
        return "file"
    }
}

struct InboxGooeyCircleLabel: View {
    let icon: String
    let size: CGFloat

    var body: some View {
        LucideIcon(name: icon, size: size * 0.34)
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: Circle())
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

struct ComposeSendCapsuleLabel: View {
    let title: String
    let icon: String
    let isWorking: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: InboxDesign.Spacing.small) {
            if isWorking {
                ProgressView()
                    .tint(.primary)
            } else {
                LucideIcon(name: icon, size: 18)
            }
            Text(title)
                .font(InboxDesign.Typography.font(.headline, weight: .semibold))
        }
        .padding(.horizontal, InboxDesign.Spacing.large)
        .frame(minWidth: 118, minHeight: 54)
        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
        .background(Color.primary, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06), lineWidth: 0.6)
        }
        .contentShape(Capsule())
    }
}

private enum AttachmentImportError: LocalizedError {
    case unreadable
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "That item could not be read."
        case .tooLarge(let filename): "\(filename) is larger than the 20 MB attachment limit."
        }
    }
}
