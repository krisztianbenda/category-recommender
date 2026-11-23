// New label…: where a label the owner names goes, and what creating it does. Synthetic labels only.
import Testing

@testable import MailCore

struct NewLabelTests {
    let catalog = LabelCatalog(
        mailboxes: ["INBOX", "[Gmail]/Trash", "Family", "Family/Baby", "Travelling", "Work/Clients/Acme"],
        inbox: "INBOX")

    @Test func aNameAloneIsATopLevelLabel() {
        let form = NewLabelForm(name: "  Lisbon ")
        #expect(form.mailbox == "Lisbon")
        #expect(form.outcome(in: catalog) == .create("Lisbon"))
        #expect(form.outcome(in: catalog).action == .createTyped("Lisbon"))
    }

    @Test func aParentPutsItInsideThatLabel() {
        #expect(NewLabelForm(name: "Porto", parent: "Travelling").outcome(in: catalog) == .create("Travelling/Porto"))
        // Deeper than the recommender's two levels, as Gmail allows.
        #expect(
            NewLabelForm(name: "Beta", parent: "Work/Clients/Acme").outcome(in: catalog)
                == .create("Work/Clients/Acme/Beta"))
        // A slash in the name nests it further.
        #expect(
            NewLabelForm(name: "Europe / Lisbon", parent: "Travelling").outcome(in: catalog)
                == .create("Travelling/Europe/Lisbon"))
    }

    @Test func anEmptyNameDoesNothing() {
        #expect(NewLabelForm().outcome(in: catalog) == .empty)
        #expect(NewLabelForm(name: " / ", parent: "Family").outcome(in: catalog) == .empty)
        #expect(NewLabelForm(name: " ").outcome(in: catalog).action == nil)
    }

    @Test func aLabelThatExistsIsFiledUnderInsteadOfMadeAgain() {
        let baby = catalog.entry(forPath: "Family/Baby")!
        #expect(NewLabelForm(name: "Baby", parent: "Family").outcome(in: catalog) == .exists(baby))
        #expect(NewLabelForm(name: "Baby", parent: "Family").outcome(in: catalog).action == .existing(baby))
        // The service folds case and accents, so these are the same category.
        #expect(NewLabelForm(name: "baby", parent: "Family").outcome(in: catalog) == .exists(baby))
        #expect(NewLabelForm(name: "Fámily").outcome(in: catalog) == .exists(catalog.entry(forPath: "Family")!))
        // A parent that only a nested label implies is filed under too, which creates it.
        let work = catalog.entry(forPath: "Work")!
        #expect(!work.existsInAccount)
        #expect(NewLabelForm(name: "work").outcome(in: catalog) == .exists(work))
    }

    @Test func theAccountsOwnMailboxesAreRefused() {
        #expect(NewLabelForm(name: "Inbox").outcome(in: catalog) == .reserved("Inbox"))
        #expect(NewLabelForm(name: "[Gmail]/Drafts").outcome(in: catalog).action == nil)
        // A folder account's own folders, by the names they have in its language.
        let folders = LabelCatalog(mailboxes: ["INBOX", "Gesendet", "Projects"], system: ["Gesendet"], inbox: "INBOX")
        #expect(NewLabelForm(name: "Gesendet").outcome(in: folders) == .reserved("Gesendet"))
        #expect(NewLabelForm(name: "Gesendet", parent: "Projects").outcome(in: folders) == .create("Projects/Gesendet"))
    }

    @Test func aFolderInsideTheInboxCanHoldANewOne() {
        // iCloud and other folder accounts name their Inbox "INBOX"; its folders are the owner's.
        let folders = LabelCatalog(mailboxes: ["INBOX", "INBOX/Receipts", "Bills"], inbox: "INBOX")
        let receipts = folders.entries.first { $0.mailbox == "INBOX/Receipts" }!
        #expect(
            NewLabelForm(name: "2026", parent: receipts.mailbox).outcome(in: folders) == .create("INBOX/Receipts/2026"))
        #expect(NewLabelForm(name: "INBOX/Other").outcome(in: folders).isReserved)
    }

    @Test func startsFromWhatWasTypedInTheSearch() {
        #expect(NewLabelForm.from(query: "", catalog: catalog) == NewLabelForm())
        #expect(NewLabelForm.from(query: " Lisbon ", catalog: catalog) == NewLabelForm(name: "Lisbon"))
        #expect(
            NewLabelForm.from(query: "travelling / Por", catalog: catalog)
                == NewLabelForm(name: "Por", parent: "Travelling"))
        #expect(
            NewLabelForm.from(query: "Work/Clients/Acme/B", catalog: catalog)
                == NewLabelForm(name: "B", parent: "Work/Clients/Acme"))
        // A parent that is not a label stays in the name, and is created with it.
        #expect(NewLabelForm.from(query: "Hobbies/Chess", catalog: catalog) == NewLabelForm(name: "Hobbies/Chess"))
        #expect(NewLabelForm.from(query: "Hobbies/", catalog: catalog) == NewLabelForm(name: "Hobbies/"))
    }

    @Test func aSearchEndingInASlashStartsANameInsideThatLabel() {
        #expect(NewLabelForm.from(query: "Travelling/", catalog: catalog) == NewLabelForm(parent: "Travelling"))
        #expect(NewLabelForm.from(query: "Travelling / ", catalog: catalog) == NewLabelForm(parent: "Travelling"))
    }

    @Test func theParentInTheSearchIsFoundAsTheServiceWouldFindIt() {
        // An accent or case typo is still the existing label, not a second, look-alike one.
        #expect(
            NewLabelForm.from(query: "Trav\u{E9}lling/Porto", catalog: catalog)
                == NewLabelForm(name: "Porto", parent: "Travelling"))
        // A deep label by the path the window shows for it.
        #expect(
            NewLabelForm.from(query: "Work/Clients \u{203A} Acme/B", catalog: catalog)
                == NewLabelForm(name: "B", parent: "Work/Clients/Acme"))
    }

    @Test func typingInTheSearchOffersCreateOnlyForWhatIsNew() {
        func offersCreate(_ query: String) -> Bool {
            LabelPicker.rows(catalog: catalog, suggestion: nil, canTrash: false, query: query)
                .contains { $0.section == .create }
        }
        #expect(offersCreate("Travelling/Porto"))
        #expect(!offersCreate("travelling"))
        // The same category as an existing deep label once accents are folded.
        #expect(!offersCreate("Work/Clients/Acm\u{E9}"))
    }
}
