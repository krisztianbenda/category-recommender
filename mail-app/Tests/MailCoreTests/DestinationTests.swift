// The address rule (specs/005-mail-app-lan, research R3). No network: names resolve through a stub.
import Foundation
import Testing

@testable import MailCore

struct DestinationTests {
    @Test(arguments: [
        "http://127.0.0.1:8080", "https://127.0.0.1:8443", "http://localhost:8080", "http://[::1]:8080",
    ])
    func loopbackIsAllowedWithoutTrust(url: String) {
        #expect(Destination.check(URL(string: url)!, trusted: false))
        #expect(Destination.check(URL(string: url)!, trusted: true))
    }

    @Test(arguments: [
        "https://10.1.2.3:8443", "https://172.16.0.1:8443", "https://172.31.255.255:8443",
        "https://192.168.1.10:8443", "https://[fd12::1]:8443", "https://mini.local:8443",
        "https://krisz-mac-mini.local", "https://mini.home.arpa:8443",
    ])
    func homeNetworkNeedsTrust(url: String) {
        #expect(!Destination.check(URL(string: url)!, trusted: false))
        #expect(Destination.check(URL(string: url)!, trusted: true))
    }

    @Test(arguments: [
        "https://172.15.0.1:8443", "https://172.32.0.1:8443", "https://8.8.8.8", "https://[2001:db8::1]",
        "https://169.254.1.1", "https://[fe80::1]", "https://mini.example.com", "https://mini",
        "https://mini.local.example.com", "https://.local", "https://mi_ni.local",
    ])
    func everythingElseIsRefused(url: String) {
        #expect(!Destination.check(URL(string: url)!, trusted: true))
    }

    @Test(arguments: ["http://192.168.1.10:8080", "http://mini.local:8080", "http://10.0.0.1"])
    func plainHTTPOnlyToThisMac(url: String) {
        #expect(!Destination.check(URL(string: url)!, trusted: true))
    }

    @Test(arguments: [
        "https://user@192.168.1.10:8443", "https://user:pass@mini.local", "http://127.0.0.1@example.com/",
        "ftp://127.0.0.1", "https://127.0.0.1.example.com",
    ])
    func userInfoAndOtherSchemesAreRefused(url: String) {
        #expect(!Destination.check(URL(string: url)!, trusted: true))
    }

    @Test func onlyNamesNeedResolving() {
        #expect(Destination.needsResolving(URL(string: "https://mini.local:8443")!))
        #expect(!Destination.needsResolving(URL(string: "https://192.168.1.10:8443")!))
        #expect(!Destination.needsResolving(URL(string: "https://[fd12::1]:8443")!))
        #expect(!Destination.needsResolving(URL(string: "http://localhost:8080")!))
    }

    @Test func aNameMustResolveIntoTheHomeNetwork() {
        func resolves(_ answers: [String]?) -> Bool {
            Destination.resolvesToHomeNetwork("mini.local") { _ in answers }
        }
        #expect(resolves(["192.168.1.10"]))
        #expect(resolves(["fd00::10"]))
        // What Bonjour answers for a Mac with IPv6 from the provider.
        #expect(resolves(["fe80::1c2b:3a4d:5e6f:7081%en0", "2a01:db8::10", "192.168.1.10"]))
        #expect(!resolves(["192.168.1.10", "203.0.113.7"]))
        #expect(!resolves(["203.0.113.7"]))
        #expect(!resolves(["fe80::1%en0", "2a01:db8::10"]))
        #expect(!resolves(["169.254.10.10"]))
        #expect(!resolves([]))
        #expect(!resolves(nil))
    }

    @Test func theSystemResolverAnswersForLoopback() {
        #expect(Destination.systemResolve("localhost")?.contains { $0 == "127.0.0.1" || $0 == "::1" } == true)
        #expect(Destination.systemResolve("no-such-host.invalid") == nil)
    }
}
