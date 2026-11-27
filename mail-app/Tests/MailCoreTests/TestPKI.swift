// Throwaway certificates for the trust tests, made with openssl in a temporary directory outside
// the repository (constitution II: never a real key or certificate).
import Foundation
import Security

final class TestPKI {
    let dir: URL

    /// The owner's CA, a server certificate it issued, and a client certificate it issued.
    private(set) var caPEM = Data()
    private(set) var server: SecCertificate!
    private(set) var client: SecCertificate!
    /// Another authority, with a server certificate for the same names.
    private(set) var otherCAPEM = Data()
    private(set) var otherServer: SecCertificate!

    static let serverNames = "IP:127.0.0.1,DNS:localhost,DNS:test-mini.local"

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catrec-test-pki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try authority("ca")
        try issue("server", subject: "/CN=test-mini", by: "ca",
            ext: "basicConstraints=CA:FALSE\nsubjectAltName=\(Self.serverNames)\nextendedKeyUsage=serverAuth\n")
        try issue("client", subject: "/CN=test-device", by: "ca",
            ext: "basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\n")
        try authority("other")
        try issue("other-server", subject: "/CN=test-mini", by: "other",
            ext: "basicConstraints=CA:FALSE\nsubjectAltName=\(Self.serverNames)\nextendedKeyUsage=serverAuth\n")
        caPEM = try Data(contentsOf: dir.appendingPathComponent("ca.crt"))
        otherCAPEM = try Data(contentsOf: dir.appendingPathComponent("other.crt"))
        server = try certificate("server")
        client = try certificate("client")
        otherServer = try certificate("other-server")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }

    func certificate(_ base: String) throws -> SecCertificate {
        let der = try openssl(["x509", "-in", "\(base).crt", "-outform", "DER"])
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TestPKIError.failed("decode \(base)")
        }
        return certificate
    }

    private func authority(_ base: String) throws {
        try key(base)
        try openssl(["req", "-new", "-key", "\(base).key", "-out", "\(base).csr", "-subj", "/CN=catrec-test-\(base)"])
        try write("\(base).ext", "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n")
        try openssl([
            "x509", "-req", "-in", "\(base).csr", "-signkey", "\(base).key", "-out", "\(base).crt", "-days", "30",
            "-sha256", "-extfile", "\(base).ext",
        ])
    }

    private func issue(_ base: String, subject: String, by ca: String, ext: String) throws {
        try key(base)
        try openssl(["req", "-new", "-key", "\(base).key", "-out", "\(base).csr", "-subj", subject])
        try write("\(base).ext", ext)
        try openssl([
            "x509", "-req", "-in", "\(base).csr", "-CA", "\(ca).crt", "-CAkey", "\(ca).key", "-CAcreateserial",
            "-out", "\(base).crt", "-days", "30", "-sha256", "-extfile", "\(base).ext",
        ])
    }

    private func key(_ base: String) throws {
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "\(base).key"])
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    @discardableResult
    private func openssl(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["openssl"] + arguments
        process.currentDirectoryURL = dir
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestPKIError.failed(arguments.joined(separator: " ")) }
        return data
    }
}

enum TestPKIError: Error {
    case failed(String)
}
