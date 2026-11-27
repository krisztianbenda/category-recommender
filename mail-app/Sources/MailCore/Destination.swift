// Where the app may send requests (specs/005-mail-app-lan, FR-003 to FR-005, research R3). The
// service on this Mac over loopback, as before; or, with the owner's CA and a device certificate set
// up, HTTPS to an address on the home network. Everything else is refused before anything is sent.
// The TLS check against the owner's CA (RecommenderTrust) is what keeps content from an impostor;
// this rule is the second wall, and catches a mistyped setting early.
import Darwin
import Foundation

public enum Destination {
    static let loopbackNames: Set<String> = ["127.0.0.1", "localhost", "::1"]
    static let homeSuffixes = [".local", ".home.arpa"]

    /// The host without the brackets of an IPv6 literal, lower-cased.
    static func host(of url: URL) -> String? {
        guard var host = url.host, !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.lowercased()
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.user == nil, url.password == nil, let host = host(of: url)
        else { return false }
        return loopbackNames.contains(host)
    }

    /// `trusted`: the owner's CA and a device certificate are set up.
    public static func check(_ url: URL, trusted: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.user == nil, url.password == nil, let host = host(of: url)
        else { return false }
        if loopbackNames.contains(host) { return true }
        guard scheme == "https", trusted else { return false }
        if let address = IPAddress(host) { return address.isHomeNetwork }
        return isHomeName(host)
    }

    /// Whether the host is a name that must be resolved before use, rather than an address.
    public static func needsResolving(_ url: URL) -> Bool {
        guard let host = host(of: url) else { return false }
        return !loopbackNames.contains(host) && IPAddress(host) == nil
    }

    static func isHomeName(_ host: String) -> Bool {
        guard let suffix = homeSuffixes.first(where: { host.hasSuffix($0) }) else { return false }
        let labels = host.dropLast(suffix.count).split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty
            && labels.allSatisfy { label in
                (1...63).contains(label.count)
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
    }

    /// A name passes when it resolves to at least one address on the home network and to no public
    /// IPv4 address. Bonjour also answers with the Mac's IPv6 link-local address, and with its
    /// global IPv6 address when the provider gives one, so IPv6 answers alone do not fail a name.
    public static func resolvesToHomeNetwork(
        _ host: String, resolver: (String) -> [String]? = Destination.systemResolve
    ) -> Bool {
        guard let addresses = resolver(host)?.compactMap(IPAddress.init), !addresses.isEmpty else { return false }
        let publicIPv4 = addresses.contains { $0.isIPv4 && !$0.isHomeNetwork && !$0.isLinkLocal }
        return !publicIPv4 && addresses.contains { $0.isHomeNetwork }
    }

    /// Every address the system resolver gives for a name, or nil when it does not resolve.
    public static func systemResolve(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if info.pointee.ai_family == AF_INET, let raw = info.pointee.ai_addr {
                raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var address = $0.pointee.sin_addr
                    if inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil {
                        out.append(String(cString: buffer))
                    }
                }
            } else if info.pointee.ai_family == AF_INET6, let raw = info.pointee.ai_addr {
                raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    var address = $0.pointee.sin6_addr
                    if inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil {
                        out.append(String(cString: buffer))
                    }
                }
            }
            cursor = info.pointee.ai_next
        }
        return out
    }
}

/// An IPv4 or IPv6 address, parsed with `inet_pton`.
struct IPAddress: Equatable {
    let bytes: [UInt8]

    init?(_ text: String) {
        let plain = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
        } else if inet_pton(AF_INET6, plain, &v6) == 1 {
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
        } else {
            return nil
        }
    }

    var isIPv4: Bool { bytes.count == 4 }

    /// Loopback, or the private ranges a home network uses: 10.0.0.0/8, 172.16.0.0/12,
    /// 192.168.0.0/16, and IPv6 unique local addresses (fc00::/7).
    var isHomeNetwork: Bool {
        if isIPv4 {
            return bytes[0] == 127 || bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
        }
        return bytes == [UInt8](repeating: 0, count: 15) + [1] || bytes[0] & 0xFE == 0xFC
    }

    /// 169.254.0.0/16 or fe80::/10: never accepted as an address, ignored among a name's answers.
    var isLinkLocal: Bool {
        isIPv4 ? bytes[0] == 169 && bytes[1] == 254 : bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
    }
}
