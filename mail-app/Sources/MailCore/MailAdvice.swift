// What the windows say about Mail's and the service's answers. Shared by the single-email window and
// the batch window, so that the same problem reads the same in both.
import Foundation

public enum MailAdvice {
    /// What to allow so that the app can use Mail's menus. Nil when permissions are not the problem.
    public static func menu(_ problem: MenuProblem) -> String? {
        switch problem {
        case .notAllowed:
            return "macOS does not let Category Recommender use Mail's menus. Turn it on in System Settings "
                + "> Privacy & Security > Accessibility. If it is on already, that entry is from before the app "
                + "was reinstalled: remove it with \u{2212}, and add the app again."
        case .systemEventsNotAllowed:
            return "macOS does not let Category Recommender use System Events. Turn on System Events under "
                + "Category Recommender in System Settings > Privacy & Security > Automation."
        case .commandUnavailable:
            return nil
        }
    }

    public static func trash(_ result: TrashResult) -> String? {
        switch result {
        case .trashed:
            return nil
        case .notAllowed, .systemEventsNotAllowed:
            let problem: MenuProblem = result == .notAllowed ? .notAllowed : .systemEventsNotAllowed
            return "Not moved to the Trash. \(menu(problem)!) For now, press Delete in Mail."
        case .commandUnavailable:
            return "Not moved to the Trash, because Mail's Delete command was not available. "
                + "Click the email in Mail's list, and try again."
        case .selectionChanged:
            return "Not moved to the Trash, because the selection in Mail changed."
        case .alreadyInTrash:
            return "It is in the Trash already. Deleting it there would erase it for good, so nothing was done."
        case .noTrash:
            return "Not moved to the Trash, because Mail shows no Trash for this account."
        case .notInTrash:
            return "Mail did not put it in the Trash. Check it in Mail, and the Trash setting under "
                + "Mail > Settings > Accounts > Mailbox Behaviors."
        }
    }

    /// The same for a batch, where the app selects the emails itself: `selectionChanged` then means
    /// Mail would not select exactly them, for example inside a collapsed conversation.
    public static func batchTrash(_ result: TrashResult, selectErrors: [Int]? = nil) -> String? {
        result == .selectionChanged
            ? "Not moved to the Trash, because Mail would not select just this email." + errorCodes(selectErrors)
                + " " + conversationHint
            : trash(result)
    }

    /// Mail's error numbers, for a report: never names or text.
    static func errorCodes(_ numbers: [Int]?) -> String {
        guard let numbers, !numbers.isEmpty else { return "" }
        return " (Mail error \(numbers.map(String.init).joined(separator: ", ")))"
    }

    /// Why emails filed from the Inbox are still there, in a batch. Nil when they were archived.
    public static func batchArchive(_ result: ArchiveResult, selectErrors: [Int]? = nil) -> String? {
        switch result {
        case .archived:
            return nil
        case .notAllowed, .systemEventsNotAllowed:
            let problem: MenuProblem = result == .notAllowed ? .notAllowed : .systemEventsNotAllowed
            return "Labelled, but still in the Inbox. \(menu(problem)!)"
        case .commandUnavailable:
            return "Labelled, but still in the Inbox, because Mail's Archive command was not available."
        case .selectionChanged:
            return "Labelled, but still in the Inbox, because Mail would not select just this email."
                + errorCodes(selectErrors) + " " + conversationHint
        case .stillThere:
            return "Labelled, but Mail did not archive it, so it is still in the Inbox."
        }
    }

    static let conversationHint =
        "If View > Organize by Conversation is on in Mail, expand the conversation or turn it off, and try again."

    public static func describe(_ error: Error) -> String {
        switch error {
        case ServiceError.unreachable:
            return "The local recommendation service is not responding."
        case ServiceError.api(_, let code, let message):
            return code == "llm_unavailable" ? "The local model is unavailable. Try again shortly." : message
        case ServiceError.notLoopback:
            return "Refused: the service address must be on this computer."
        case ServiceError.badResponse:
            return "The local service gave an unexpected answer."
        case MailError.notAuthorized:
            return "Mail access is not allowed. Turn it on in System Settings > Privacy & Security > Automation."
        case MailError.mailNotRunning:
            return "Mail is not open."
        case MailError.timedOut:
            return "Mail did not answer in time."
        case MailError.notFound(let message):
            return message
        case MailError.script(_, let message):
            return message
        default:
            return (error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error))
        }
    }
}
