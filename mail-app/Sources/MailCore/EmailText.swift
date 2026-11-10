// Prepares an email for the service: clean text within the API's limits. The same value is sent
// with the suggestion and with its feedback, because the service compares their hashes.
import Foundation

public enum EmailText {
    /// The service reads far less than this; the rest only costs memory and transfer time.
    static let maxBody = 50_000
    static let maxSubject = 2_000
    static let maxAddress = 500
    static let maxRecipients = 100

    public static func prepared(_ email: Email) -> Email {
        Email(
            from: clip(email.from, maxAddress),
            to: email.to.map { Array($0.prefix(maxRecipients)).map { clip($0, maxAddress) } },
            subject: clip(email.subject, maxSubject),
            body: clip(tidy(email.body), maxBody))
    }

    /// Plain text rendered from HTML is often mostly blank space, which would use up the budget.
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        var blanks = 0
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = LabelText.collapse(String(raw))
            if line.isEmpty {
                blanks += 1
                if blanks > 1 { continue }
            } else {
                blanks = 0
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts on a character boundary, measuring in UTF-16 units as the service does.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var out = ""
        for character in text {
            if out.utf16.count + character.utf16.count > limit { break }
            out.append(character)
        }
        return out
    }
}
