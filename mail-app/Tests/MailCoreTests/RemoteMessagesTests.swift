// What the windows say about a recommender on the home network (specs/005-mail-app-lan, FR-011 to
// FR-014, research R4). Synthetic emails, a fake Mail and a fake service; no network.
import Foundation
import Testing

@testable import MailCore

@Test(arguments: [
    (ServiceError.unreachable, "Mac mini can't be reached. You can still file by hand, but it won't be learned."),
    (ServiceError.untrusted, "Mac mini could not prove who it is, so nothing was sent."),
    (ServiceError.notAllowed, "Mac mini does not accept this Mac. Check its device list."),
    (
        ServiceError.noDeviceCertificate,
        "This Mac's device certificate is not installed. Open its .p12 file to add it to the keychain."
    ),
    (
        ServiceError.api(status: 503, code: "llm_unavailable", message: "later"),
        "The model on Mac mini is unavailable. Try again shortly."
    ),
])
func remoteMessagesNameTheRecommender(error: ServiceError, text: String) {
    #expect(MailAdvice.describe(error, remote: "Mac mini") == text)
}

@Test func otherErrorsKeepTheirOwnText() {
    #expect(MailAdvice.describe(ServiceError.api(status: 400, code: "bad", message: "Bad request"), remote: "Mac mini") == nil)
    #expect(MailAdvice.describe(MailError.mailNotRunning, remote: "Mac mini") == nil)
}

/// The windows with the recommender named "Mac mini", for these tests' tasks only.
@MainActor
struct RemoteWindowTests {
    let mail = FakeMail()
    let api = FakeAPI()
    let backend = FakeBackend()

    private func asMacMini<T>(_ body: () async throws -> T) async rethrows -> T {
        try await MailAdvice.$testPlace.withValue(.named("Mac mini")) { try await body() }
    }

    @Test func theSourceIsNamed() async {
        await asMacMini {
            #expect(MailAdvice.source == "Recommendations from Mac mini")
            #expect(MailAdvice.starting == "The recommender on Mac mini is starting\u{2026}")
            #expect(MailAdvice.thinking == "Asking Mac mini\u{2026}")
        }
        #expect(MailAdvice.source == "Recommendations from this Mac")
        #expect(MailAdvice.starting == "Starting the local model. Only the first email takes a while.")
    }

    @Test(arguments: [ServiceError.unreachable, .untrusted, .notAllowed, .noDeviceCertificate])
    func eachCauseIsSaidAndFilingByHandIsNotLearned(error: ServiceError) async {
        backend.error = error
        await asMacMini {
            let s = RecommenderSession(mail: mail, api: api, backend: backend)
            await s.start().value
            #expect(s.recommendation == .unavailable(MailAdvice.describe(error, remote: "Mac mini")!))
            await s.accept(s.rows.first { $0.title == "Gadgets" }!)?.value
            #expect(mail.filed.map(\.target) == ["Gadgets"])
            #expect(api.suggestCalls.isEmpty && api.feedbacks.isEmpty && backend.starts == 0)
        }
    }

    @Test func theBatchWindowSaysItOnceAndEveryRowCanBeFiledByHand() async {
        backend.error = ServiceError.unreachable
        let text = "Mac mini can't be reached. You can still file by hand, but it won't be learned."
        await asMacMini {
            let opening = mail.opening([
                Email(from: "Dad <dad@example.test>", subject: "Sunday lunch", body: "See you at noon"),
                Email(from: "Clinic <clinic@example.test>", subject: "Baby check-up", body: "Friday 10:00"),
            ])
            let s = BatchSession(mail: mail, api: api, backend: backend)
            await s.start(with: opening).value
            await s.settle()
            #expect(s.notice == text)
            #expect(s.rows.allSatisfy { $0.recommendation == .unavailable(text) })
            s.highlight("m:m1")
            s.openPicker(query: "Gadgets")
            await s.choosePickerHighlighted()?.value
            await s.settle()
            #expect(mail.filed.map(\.target) == ["Gadgets"])
            #expect(api.feedbacks.isEmpty)
            #expect(api.suggestCalls.isEmpty)
        }
    }
}
