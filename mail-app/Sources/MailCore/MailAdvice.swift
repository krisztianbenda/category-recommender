// What the windows say about Mail's and the service's answers. Shared by the single-email window and
// the batch window, so that the same problem reads the same in both.
import Foundation

/// Where recommendations come from (spec 005, FR-011).
public enum RecommenderPlace: Equatable, Sendable {
    case thisMac
    /// A recommender on the home network, by the name the owner knows it by, such as "Mac mini".
    case named(String)
}

public enum MailAdvice {
    /// Set once at start-up, before any window opens.
    public static var recommender: RecommenderPlace {
        get { testPlace ?? configured }
        set { configured = newValue }
    }
    nonisolated(unsafe) private static var configured: RecommenderPlace = .thisMac
    /// For tests: a place for one task and the tasks it starts, so tests can run side by side.
    @TaskLocal static var testPlace: RecommenderPlace?

    /// The first menu item.
    public static var source: String {
        switch recommender {
        case .thisMac: return "Recommendations from this Mac"
        case .named(let name): return "Recommendations from \(name)"
        }
    }

    /// While the model is loading.
    public static var starting: String {
        switch recommender {
        case .thisMac: return "Starting the local model. Only the first email takes a while."
        case .named(let name): return "The recommender on \(name) is starting\u{2026}"
        }
    }

    /// While the batch window waits for the model.
    public static var startingShort: String {
        switch recommender {
        case .thisMac: return "Starting the local model\u{2026}"
        case .named(let name): return "The recommender on \(name) is starting\u{2026}"
        }
    }

    /// While a recommendation is being made.
    public static var thinking: String {
        switch recommender {
        case .thisMac: return "Reading the email on this computer\u{2026}"
        case .named(let name): return "Asking \(name)\u{2026}"
        }
    }

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
        if case .named(let name) = recommender, let text = describe(error, remote: name) { return text }
        switch error {
        case ServiceError.unreachable:
            return "The local recommendation service is not responding."
        case ServiceError.api(_, let code, let message):
            return code == "llm_unavailable" ? "The local model is unavailable. Try again shortly." : message
        case ServiceError.destinationRefused:
            return "Refused: the recommender's address is not on this Mac or the home network."
        case ServiceError.badResponse:
            return "The local service gave an unexpected answer."
        case ServiceError.untrusted:
            return "The recommender could not prove who it is, so nothing was sent."
        case ServiceError.notAllowed:
            return "The recommender does not accept this Mac. Check its device list."
        case ServiceError.noDeviceCertificate:
            return noDeviceCertificate
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

    static let noDeviceCertificate =
        "This Mac's device certificate is not installed. Open its .p12 file to add it to the keychain."

    /// The service's errors for a recommender on the home network. Nil for every other error.
    static func describe(_ error: Error, remote name: String) -> String? {
        switch error {
        case ServiceError.unreachable:
            return "\(name) can't be reached. You can still file by hand, but it won't be learned."
        case ServiceError.untrusted:
            return "\(name) could not prove who it is, so nothing was sent."
        case ServiceError.notAllowed:
            return "\(name) does not accept this Mac. Check its device list."
        case ServiceError.noDeviceCertificate:
            return noDeviceCertificate
        case ServiceError.api(_, "llm_unavailable", _):
            return "The model on \(name) is unavailable. Try again shortly."
        case ServiceError.badResponse:
            return "\(name) gave an unexpected answer."
        default:
            return nil
        }
    }
}
