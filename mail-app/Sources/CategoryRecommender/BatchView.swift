// The batch window (specs/004-batch-recommendations/contracts/batch-window.md): one row per selected
// email with its own recommendation. Every action works on the marked rows, else the highlighted
// row; approve all works on every ready row. Keys are handled by PanelController.
import MailCore
import SwiftUI

struct BatchView: View {
    @ObservedObject var session: BatchSession

    var body: some View {
        Group {
            switch session.stage {
            case .reading:
                centered { ProgressView().controlSize(.small) }
            case .blocked(let reason):
                centered {
                    VStack(spacing: 10) {
                        Image(systemName: "envelope").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(Self.blockedText(reason)).font(.callout).multilineTextAlignment(.center)
                        Button("Close") { session.close() }.keyboardShortcut(.defaultAction)
                    }
                    .padding(28)
                }
            case .ready:
                if session.pickerScope != nil {
                    BatchPicker(session: session)
                } else {
                    BatchList(session: session)
                }
            }
        }
        .frame(width: PanelController.batchWidth, height: PanelController.batchHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if let confirmation = session.confirmation {
                BatchConfirmationView(session: session, confirmation: confirmation)
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    static func blockedText(_ reason: BlockReason) -> String {
        switch reason {
        case .mailNotRunning: return "Mail is not open. Open Mail, select emails, and try again."
        case .noSelection: return "Select emails in Mail, and try again."
        case .unsupportedSelection:
            return "Select emails from one account at a time. Emails under On My Mac can't be filed."
        case .noAccount: return "Add your email account in System Settings > Internet Accounts."
        case .notAuthorized:
            return "Turn on Mail for Category Recommender in System Settings > Privacy & Security > Automation."
        case .other(let message): return message
        }
    }
}

// MARK: List

private struct BatchList: View {
    @ObservedObject var session: BatchSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.rows) { row in
                            BatchRowView(session: session, row: row).id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: session.highlightedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(session.rows.count) emails").font(.headline)
            if session.leftOut > 0 {
                Text("\(session.leftOut) more were selected and left out. They are not changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = session.notice { NoticeText(text: notice) }
            HStack(spacing: 10) {
                if session.modelStarting {
                    ProgressView().controlSize(.small)
                    Text(MailAdvice.startingShort).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(session.readyCount) of \(session.rows.count) ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Keep in Inbox", isOn: $session.keepInInbox)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
            }
            HStack(spacing: 8) {
                let marked = session.markedCount
                let suffix = marked > 0 ? " for \(marked) marked" : ""
                Button("Move to Trash\(suffix)") { session.moveScopeToTrash() }
                    .help("\u{2318}\u{232B}")
                    .disabled(!session.accountHasTrash || session.scope.isEmpty)
                Button("Choose \(session.noun)\u{2026}\(marked > 0 ? suffix : "")") { session.openPicker() }
                    .help("\u{2192}")
                    .disabled(session.scope.isEmpty)
                Spacer()
                if marked > 0 {
                    Button("Approve \(marked) marked") { session.acceptScope() }
                        .help("\u{23CE}")
                }
                Button("Approve all (\(session.approvable.count))") { session.approveAll() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(session.approvable.isEmpty)
            }
            .controlSize(.small)
            Text("\u{2191}\u{2193} move   space mark   \u{23CE} accept   \u{2318}\u{23CE} approve all   \u{232B} skip   esc close")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct BatchRowView: View {
    @ObservedObject var session: BatchSession
    let row: BatchRow

    private var highlighted: Bool { session.highlightedID == row.id }
    private var dimmed: Bool { row.state == .done || row.skipped }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 10) {
            Image(systemName: row.marked ? "checkmark.square.fill" : "square")
                .foregroundStyle(row.marked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .onTapGesture { session.toggleMark(row.id) }
                .opacity(row.isOpen ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(row.sender)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            recommendation
                .frame(width: 230, alignment: .trailing)
        }
        // What happened, in full, under the row: it can be advice to follow.
        state
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 28)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlighted ? Color.accentColor.opacity(0.18) : .clear)
        )
        .padding(.horizontal, 6)
        .opacity(dimmed ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { session.highlight(row.id) }
        .onTapGesture(count: 2) {
            session.highlight(row.id)
            session.openPicker()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var recommendation: some View {
        switch row.recommendation {
        case .none, .thinking, .startingModel:
            ProgressView().controlSize(.mini)
        case .unavailable(let reason):
            Text("No recommendation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(reason)
        case .ready(let suggestion):
            HStack(spacing: 6) {
                if let recommended = row.recommended {
                    Text(title(recommended))
                        .font(.callout)
                        .foregroundStyle(recommended.action == .trash ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ConfidenceBadge(confidence: suggestion.confidence)
            }
            .help(suggestion.reason)
        }
    }

    @ViewBuilder private var state: some View {
        switch row.state {
        case .applying:
            Text("Applying\u{2026}").font(.caption2).foregroundStyle(.secondary)
        case .applied, .done:
            Text([row.outcome, row.notice].compactMap { $0 }.joined(separator: " "))
                .font(.caption2)
                .foregroundStyle(row.notice == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
        case .problem:
            Text(row.notice ?? "Not applied.")
                .font(.caption2)
                .foregroundStyle(.red)
        case .pending, .ready:
            if row.skipped {
                Text("Skipped").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func title(_ recommended: LabelRow) -> String {
        switch recommended.action {
        case .trash: return "Move to Trash"
        case .acceptProposal, .recreate, .createTyped: return "New: \(recommended.title)"
        case .existing: return recommended.title
        }
    }
}

private struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var text: String {
        switch confidence {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        }
    }

    private var color: Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}

// MARK: Choose a label

private struct BatchPicker: View {
    @ObservedObject var session: BatchSession
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(heading).font(.headline).lineLimit(1)
                if let suggestion = session.pickerRow?.suggestion, !suggestion.reason.isEmpty {
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 30)
            .padding(.bottom, 10)
            Divider()
            if session.newLabel != nil {
                NewLabelPane(session: session)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(session.noun)s, or name a new one", text: $session.pickerQuery)
                        .textFieldStyle(.plain)
                        .modifier(FocusAtEnd(focus: $searchFocused))
                    Button {
                        session.openNewLabel()
                    } label: {
                        Label("New \(session.noun)\u{2026}", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Create a \(session.noun) and choose where it goes (\u{2318}N)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(session.pickerRows) { row in
                                PickerRow(session: session, row: row).id(row.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: session.pickerHighlightedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            Text(keys)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private var keys: String {
        if session.newLabel != nil {
            let enter = session.newLabelOutcome.isExisting ? "file" : "create"
            return "\u{2191}\u{2193} location   \u{23CE} \(enter)   esc back"
        }
        return "\u{23CE} file   \u{2318}N new \(session.noun)   \u{2318}\u{232B} trash   esc back"
    }

    private var heading: String {
        if let row = session.pickerRow { return "For: \(row.subject.isEmpty ? "(no subject)" : row.subject)" }
        return "For \(session.pickerScope?.count ?? 0) emails"
    }
}

/// Focuses a field when it appears, with the caret after its text. macOS selects all of a field's
/// text when it takes focus, so the next key would replace what was typed before it opened.
private struct FocusAtEnd: ViewModifier {
    let focus: FocusState<Bool>.Binding
    /// Only the first focus: a later click places the caret where the owner clicked.
    @State private var placed = false

    func body(content: Content) -> some View {
        content
            .focused(focus)
            // On the next turn: when this field replaces the focused one, the focus would
            // otherwise go with the field that is leaving.
            .onAppear { DispatchQueue.main.async { focus.wrappedValue = true } }
            .onChange(of: focus.wrappedValue) { _, isFocused in
                guard isFocused, !placed else { return }
                placed = true
                DispatchQueue.main.async {
                    guard let editor = NSApp.windows.first(where: \.isKeyWindow)?.firstResponder as? NSTextView
                    else { return }
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                }
            }
    }
}

/// New label…: a name and where it goes, the top level or inside a label, as in Mail's New Mailbox.
private struct NewLabelPane: View {
    @ObservedObject var session: BatchSession
    @FocusState private var nameFocused: Bool

    var body: some View {
        let outcome = session.newLabelOutcome
        VStack(alignment: .leading, spacing: 14) {
            Text("New \(session.noun)").font(.title3.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Name:").gridColumnAlignment(.trailing)
                    TextField("Name", text: name, prompt: Text("For example, Lisbon"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .modifier(FocusAtEnd(focus: $nameFocused))
                }
                GridRow {
                    Text("Location:")
                    Picker("Location", selection: parent) {
                        Text("Top level").tag(String?.none)
                        Divider()
                        ForEach(session.newLabelParents) { entry in
                            Text(entry.path).tag(String?.some(entry.mailbox))
                        }
                    }
                    .labelsHidden()
                }
            }
            Text(message(outcome))
                .font(.callout)
                .foregroundStyle(outcome.isReserved ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Back") { session.cancelNewLabel() }
                Button(outcome.isExisting ? "File Under It" : "Create and File") {
                    session.createNewLabel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(outcome.action == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var name: Binding<String> {
        Binding(get: { session.newLabel?.name ?? "" }, set: { session.newLabel?.name = $0 })
    }

    private var parent: Binding<String?> {
        Binding(get: { session.newLabel?.parent }, set: { session.newLabel?.parent = $0 })
    }

    private var emails: String {
        let count = session.pickerScope?.count ?? 0
        return count == 1 ? "this email" : "the \(count) emails"
    }

    private func message(_ outcome: NewLabelOutcome) -> String {
        let noun = session.noun
        switch outcome {
        case .empty:
            return "Name the \(noun), choose where it goes, and \(emails) will be filed under it."
        case .create(let mailbox):
            return "Creates \u{201C}\(mailbox)\u{201D} and files \(emails) under it."
        case .exists(let entry):
            return "\u{201C}\(entry.path)\u{201D} exists already. Return files \(emails) under it."
        case .reserved(let mailbox):
            return "\u{201C}\(mailbox)\u{201D} is one of Mail's own mailboxes. Choose another name."
        }
    }
}

private struct PickerRow: View {
    @ObservedObject var session: BatchSession
    let row: LabelRow

    private var highlighted: Bool { session.pickerHighlightedID == row.id }
    private var isTrash: Bool { row.action == .trash }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16)
            Text(title)
                .font(row.section == .recommended ? .body.weight(.semibold) : .body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if highlighted { Text("\u{23CE}").font(.caption).opacity(0.8) }
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(isTrash ? Color.red : .primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlighted ? (isTrash ? Color.red : Color.accentColor) : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { session.choose(row) }
    }

    private var title: String {
        switch row.action {
        case .existing, .trash: return row.title
        case .acceptProposal, .createTyped: return "Create \u{201C}\(row.title)\u{201D}"
        case .recreate: return "Recreate \u{201C}\(row.title)\u{201D}"
        }
    }

    private var icon: String {
        switch row.action {
        case .existing: return row.section == .recommended ? "star.fill" : "tag"
        case .acceptProposal, .recreate, .createTyped: return "plus.circle"
        case .trash: return "trash"
        }
    }
}

// MARK: Confirmation

private struct BatchConfirmationView: View {
    @ObservedObject var session: BatchSession
    let confirmation: BatchConfirmation

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(alignment: .leading, spacing: 10) {
                Text(question).font(.headline)
                Text("You can get them back from the Trash in Mail.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { session.cancelConfirmation() }
                    Button("Confirm", role: .destructive) { session.confirm() }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 12)
            .padding(60)
        }
    }

    private var question: String {
        let trash = "move \(confirmation.trashCount) to the Trash"
        guard confirmation.fileCount > 0 else {
            return "Move \(confirmation.trashCount) emails to the Trash?"
        }
        let emails = confirmation.fileCount == 1 ? "email" : "emails"
        return "File \(confirmation.fileCount) \(emails) and \(trash)?"
    }
}
