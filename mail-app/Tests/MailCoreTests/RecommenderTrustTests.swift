// Trusting only the owner's CA (specs/005-mail-app-lan, research R1), with certificates the test
// makes. No network and no keychain.
import Foundation
import Security
import Testing

@testable import MailCore

@Suite(.serialized)
final class RecommenderTrustTests {
    let pki: TestPKI

    init() throws { pki = try TestPKI() }
    deinit { pki.cleanup() }

    @Test func aPEMWithOneCertificateDecodes() throws {
        _ = try RecommenderTrust(caPEM: pki.caPEM)
    }

    @Test func anythingElseIsNotACertificate() {
        #expect(throws: TrustError.notACertificate) { try RecommenderTrust(caPEM: Data("hello".utf8)) }
        #expect(throws: TrustError.notACertificate) { try RecommenderTrust(caPEM: pki.caPEM + pki.otherCAPEM) }
        let broken = Data("-----BEGIN CERTIFICATE-----\n!!!\n-----END CERTIFICATE-----\n".utf8)
        #expect(throws: TrustError.notACertificate) { try RecommenderTrust(caPEM: broken) }
    }

    @Test(arguments: ["127.0.0.1", "test-mini.local", "localhost"])
    func theOwnersServerIsTrustedForItsNames(host: String) throws {
        let trust = try RecommenderTrust(caPEM: pki.caPEM)
        #expect(trust.evaluate(chain: [pki.server], host: host))
    }

    @Test(arguments: ["192.168.1.10", "other-mini.local"])
    func notForAnotherName(host: String) throws {
        let trust = try RecommenderTrust(caPEM: pki.caPEM)
        #expect(!trust.evaluate(chain: [pki.server], host: host))
    }

    @Test func anotherAuthorityIsNotTrusted() throws {
        let trust = try RecommenderTrust(caPEM: pki.caPEM)
        #expect(!trust.evaluate(chain: [pki.otherServer], host: "127.0.0.1"))
    }

    @Test func aClientCertificateIsNotAServerCertificate() throws {
        let trust = try RecommenderTrust(caPEM: pki.caPEM)
        #expect(!trust.evaluate(chain: [pki.client], host: "127.0.0.1"))
    }

    @Test func anExpiredCertificateIsNotTrusted() throws {
        let trust = try RecommenderTrust(caPEM: pki.caPEM)
        let later = Date().addingTimeInterval(60 * 24 * 3600)
        #expect(!trust.evaluate(chain: [pki.server], host: "127.0.0.1", at: later))
    }

    @Test func theCAIssuedItsOwnCertificatesOnly() throws {
        let trust = try RecommenderTrust(caPEM: pki.caPEM)
        #expect(trust.issued(pki.client))
        #expect(!trust.issued(pki.otherServer))
    }
}
