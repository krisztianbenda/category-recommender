// The window's content. Everything is reachable by keyboard: type to search or name a new label,
// arrows to move, Return to file, Command-Delete to move to the Trash, Escape to close.
import MailCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var session: RecommenderSession

    var body: some View {
        Group {
            switch session.stage {
            case .reading:
                centered { ProgressView().controlSize(.small) }
            case .blocked(let reason):
                centered { BlockedView(reason: reason, close: session.close) }
            case .ready:
                ReadyView(session: session)
            }
        }
        .frame(width: PanelController.width, height: PanelController.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BlockedView: View {
    let reason: BlockReason
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close", action: close)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(28)
    }

    private var icon: String {
        switch reason {
        case .notAuthorized: return "lock"
        case .other: return "exclamationmark.triangle"
        default: return "envelope"
        }
    }

    private var title: String {
        switch reason {
        case .mailNotRunning: return "Mail is not open"
        case .noSelection: return "No email selected"
        case .unsupportedSelection: return "Can't file this selection"
        case .noAccount: return "No email account in Mail"
        case .notAuthorized: return "Mail access is off"
        case .other: return "Could not read from Mail"
        }
    }

    private var detail: String {
        switch reason {
        case .mailNotRunning: return "Open Mail, select an email, and try again."
        case .noSelection: return "Select an email in Mail, and try again."
        case .unsupportedSelection:
            return "Select emails from one account. Emails under On My Mac can't be filed."
        case .noAccount: return "Add your email account in System Settings > Internet Accounts."
        case .notAuthorized:
            return "Turn on Mail for Category Recommender in System Settings > Privacy & Security > Automation."
        case .other(let message): return message
        }
    }
}

private struct ReadyView: View {
    @ObservedObject var session: RecommenderSession
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            RecommendationBanner(session: session)
            searchField
            Divider()
            LabelList(session: session)
            Divider()
            footer
        }
        .overlay {
            if let request = session.deleteRequest {
                DeleteConfirmation(session: session, request: request)
            } else if let wait = session.deleteWait {
                DeleteWaiting(session: session, wait: wait)
            }
        }
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.subject.isEmpty ? "(no subject)" : session.subject)
                .font(.headline)
                .lineLimit(1)
            Text(senderLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }

    private var senderLine: String {
        session.messageCount > 1 ? "\(session.sender) and \(session.messageCount - 1) more" : session.sender
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search \(session.noun)s, or name a new one", text: $session.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = session.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.orphaned.isEmpty {
                HStack {
                    Text(orphanText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Forget") { session.forgetOrphaned() }
                        .controlSize(.small)
                }
            }
            if session.notConsidered > 0 {
                Text("\(session.notConsidered) \(session.noun)s are too many for the recommender. You can still pick them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Keep in Inbox", isOn: $session.keepInInbox)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help(
                        session.usesFolders
                            ? "File a copy, and leave the email in the Inbox"
                            : "Add the label, and leave the email in the Inbox")
                Spacer()
                Button {
                    session.moveToTrash()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(!session.canTrash || session.busy)
                .help("Move this email to the Trash (\u{2318}\u{232B})")
                if session.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var hint: String {
        session.highlightedID == LabelRow.trash.id ? "\u{23CE} trash   esc close" : "\u{23CE} file   esc close"
    }

    private var orphanText: String {
        let count = session.orphaned.count
        return count == 1
            ? "A removed \(session.noun) still holds learned decisions."
            : "\(count) removed \(session.noun)s still hold learned decisions."
    }
}

private struct RecommendationBanner: View {
    @ObservedObject var session: RecommenderSession

    var body: some View {
        Group {
            switch session.recommendation {
            case .none:
                EmptyView()
            case .startingModel:
                status("Starting the local model. Only the first email takes a while.")
            case .thinking:
                status("Reading the email on this computer\u{2026}")
            case .ready(let suggestion):
                details(suggestion)
            case .unavailable(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
            }
        }
    }

    private func status(_ text: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
        }
    }

    private func details(_ suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !suggestion.reason.isEmpty {
                Text(suggestion.reason)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(confidenceText(suggestion.confidence))
                    .foregroundStyle(confidenceColor(suggestion.confidence))
                if suggestion.similarPastDecisions > 0 {
                    Text("\u{00B7} \(suggestion.similarPastDecisions) similar past decisions")
                }
                if suggestion.similarInTrash > 0 {
                    Text("\u{00B7} \(suggestion.similarInTrash) in the Trash")
                }
                if suggestion.truncated {
                    Text("\u{00B7} long email shortened")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func confidenceText(_ confidence: Confidence) -> String {
        switch confidence {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low confidence"
        }
    }

    private func confidenceColor(_ confidence: Confidence) -> Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}

private struct LabelList: View {
    @ObservedObject var session: RecommenderSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.rows.enumerated()), id: \.element.id) { index, row in
                        if let heading = heading(at: index) {
                            Text(heading)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                        LabelRowView(session: session, row: row)
                            .id(row.id)
                    }
                    if session.rows.isEmpty {
                        Text("No \(session.noun)s")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: session.highlightedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func heading(at index: Int) -> String? {
        let section = session.rows[index].section
        if index > 0 && session.rows[index - 1].section == section { return nil }
        switch section {
        case .recommended: return "RECOMMENDED"
        case .likely: return "ALSO LIKELY"
        case .all:
            let plural = session.usesFolders ? "FOLDERS" : "LABELS"
            return session.query.isEmpty ? "ALL \(plural)" : "MATCHING \(plural)"
        case .create: return session.usesFolders ? "NEW FOLDER" : "NEW LABEL"
        }
    }
}

private struct LabelRowView: View {
    @ObservedObject var session: RecommenderSession
    let row: LabelRow
    @State private var hovering = false

    private var highlighted: Bool { session.highlightedID == row.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(iconStyle))
                .frame(width: 16)
            Text(title)
                .font(row.section == .recommended ? .body.weight(.semibold) : .body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let entry = row.entry, hovering, !session.busy {
                Button {
                    session.askToDelete(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete this \(session.noun)")
            }
            if highlighted {
                Text("\u{23CE}")
                    .font(.caption)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlighted ? highlightColor : (hovering ? Color.primary.opacity(0.06) : .clear))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { session.accept(row) }
        .contextMenu {
            Button(isTrash ? "Move to Trash" : "File here") { session.accept(row) }
            if let entry = row.entry {
                Button("Delete \(session.noun)\u{2026}", role: .destructive) { session.askToDelete(entry) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var isTrash: Bool { row.action == .trash }

    private var title: String {
        switch row.action {
        case .existing, .trash: return row.title
        case .acceptProposal: return "Create \u{201C}\(row.title)\u{201D}"
        case .recreate: return "Recreate \u{201C}\(row.title)\u{201D}"
        case .createTyped: return "Create \u{201C}\(row.title)\u{201D}"
        }
    }

    private var icon: String {
        switch row.action {
        case .existing: return row.section == .recommended ? "star.fill" : "tag"
        case .acceptProposal, .recreate, .createTyped: return "plus.circle"
        case .trash: return "trash"
        }
    }

    /// Moving to the Trash is red, so it is not taken for filing at a glance.
    private var highlightColor: Color { isTrash ? .red : .accentColor }

    private var iconStyle: AnyShapeStyle {
        if isTrash { return AnyShapeStyle(Color.red) }
        return row.section == .recommended ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
    }
}

private struct DeleteWaiting: View {
    @ObservedObject var session: RecommenderSession
    let wait: DeleteWait

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(title).font(.headline)
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Stop Waiting") { session.cancelDeleteWait() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 12)
            .padding(24)
        }
    }

    private var title: String {
        switch wait.start {
        case .confirmInMail: return "Confirm in Mail"
        case .chooseInMail: return "Finish in Mail"
        }
    }

    private var detail: String {
        switch wait.start {
        case .confirmInMail:
            return "Mail is asking whether to delete \u{201C}\(wait.entry.path)\u{201D}. Check the name, and confirm there."
        case .chooseInMail(let problem):
            let steps = "Mail now shows \u{201C}\(wait.entry.path)\u{201D}. In Mail, choose Mailbox > Delete Mailbox, then confirm."
            guard let advice = RecommenderSession.menuAdvice(problem) else { return steps }
            return "\(steps) To skip this step next time: \(advice)"
        }
    }
}

private struct DeleteConfirmation: View {
    @ObservedObject var session: RecommenderSession
    let request: DeleteRequest

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(alignment: .leading, spacing: 10) {
                Text("Delete \u{201C}\(request.entry.path)\u{201D}?")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { session.cancelDelete() }
                        .keyboardShortcut(.cancelAction)
                    Button("Delete in Mail\u{2026}", role: .destructive) { session.confirmDelete() }
                        .disabled(session.busy)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 12)
            .padding(24)
        }
    }

    private var message: String {
        var parts: [String] = []
        if let count = request.emailCount {
            parts.append(
                count == 1 ? "This \(session.noun) holds 1 email." : "This \(session.noun) holds \(count) emails.")
        }
        parts.append(
            session.usesFolders
                ? "Mail deletes the emails in it together with the folder."
                : "The emails are not deleted. They stay in All Mail and keep their other labels.")
        if request.learnedDecisions > 0 {
            parts.append(
                "The recommender forgets \(request.learnedDecisions) decisions it learned for this \(session.noun).")
        }
        return parts.joined(separator: " ")
    }
}
