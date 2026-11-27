// Trust between this Mac and a recommender on the home network (specs/005-mail-app-lan, research R1
// and R2). The recommender must prove itself with a certificate from the owner's own CA, and the
// authorities macOS trusts for websites do not count. This Mac proves itself with its device
// certificate, whose private key stays in the keychain: nothing here reads, copies or exports a key.
import Foundation
import Security

public enum TrustError: Error, Equatable {
    /// The CA file does not hold exactly one PEM certificate.
    case notACertificate
}

public final class RecommenderTrust: @unchecked Sendable {
    public let anchor: SecCertificate
    /// For tests only: a keychain file made by the test, searched instead of the user's keychains.
    let keychainPath: String?

    public init(caPEM: Data, keychainPath: String? = nil) throws {
        guard let der = Self.der(fromPEM: caPEM), let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else { throw TrustError.notACertificate }
        anchor = certificate
        self.keychainPath = keychainPath
    }

    static func der(fromPEM data: Data) -> Data? {
        let text = String(decoding: data, as: UTF8.self)
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        let blocks = text.components(separatedBy: begin)
        guard blocks.count == 2, let body = blocks[1].components(separatedBy: end).first,
            blocks[1].contains(end)
        else { return nil }
        return Data(base64Encoded: body.filter { !$0.isWhitespace })
    }

    /// Whether the server's chain leads to the owner's CA, and its certificate names `host`.
    /// `date` is for tests: it evaluates the chain as at that moment.
    public func evaluate(_ trust: SecTrust, host: String, at date: Date? = nil) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if let date { SecTrustSetVerifyDate(trust, date as CFDate) }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// The same check for a chain of certificates, as a server presents it.
    public func evaluate(chain: [SecCertificate], host: String, at date: Date? = nil) -> Bool {
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess, let trust else {
            return false
        }
        return evaluate(trust, host: host, at: date)
    }

    /// Whether the owner's CA issued this certificate.
    func issued(_ certificate: SecCertificate) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
            let trust
        else { return false }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// This Mac's identity: the keychain identity whose label or certificate subject is `label`, and
    /// whose certificate the owner's CA issued, so another identity of the same name is never used.
    public func deviceIdentity(label: String) -> SecIdentity? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true,
        ]
        if let keychainPath {
            var keychain: SecKeychain?
            guard SecKeychainOpen(keychainPath, &keychain) == errSecSuccess, let keychain else { return nil }
            query[kSecMatchSearchList as String] = [keychain]
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        else { return nil }
        for item in items {
            guard let ref = item[kSecValueRef as String], CFGetTypeID(ref as CFTypeRef) == SecIdentityGetTypeID()
            else { continue }
            let identity = ref as! SecIdentity
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
                continue
            }
            let names = [
                item[kSecAttrLabel as String] as? String,
                SecCertificateCopySubjectSummary(certificate) as String?,
            ]
            if names.contains(label), issued(certificate) { return identity }
        }
        return nil
    }
}
