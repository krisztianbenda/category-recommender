// Starts the local service on demand and stops it after an idle period (FR-019). A service the
// owner started is used but never stopped (FR-020). Stopping releases about 5.6 GB of model memory.
import Foundation
import MailCore

final class Backend: BackendControl, @unchecked Sendable {
    struct Launch {
        let script: URL
        let path: String
    }

    enum Failure: LocalizedError {
        case notInstalled
        case exited(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "The local service is not running, and this app was not told how to start it."
            case .exited(let detail):
                return detail.isEmpty ? "The local service stopped while starting." : detail
            case .timedOut:
                return "The local model did not get ready in time."
            }
        }
    }

    private let client: ServiceClient
    private let launch: Launch?
    private let idleSeconds: TimeInterval
    private let logger: EventLog
    private let lock = NSLock()
    private var process: Process?
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?
    private var errorText = ""

    init(client: ServiceClient, launch: Launch?, idleMinutes: Double, logger: EventLog) {
        self.client = client
        self.launch = launch
        self.idleSeconds = idleMinutes * 60
        self.logger = logger
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var isManaged: Bool { withLock { process?.isRunning == true } }

    func noteActivity() {
        withLock { lastActivity = Date() }
    }

    func ensureRunning(onStarting: @escaping @Sendable () -> Void) async throws {
        if let health = try? await client.health(), health.isReady {
            noteActivity()
            return
        }
        onStarting()
        let answered = (try? await client.health()) != nil
        if !isManaged && !answered {
            try start()
        }
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if let health = try? await client.health(), health.isReady {
                noteActivity()
                return
            }
            if launch != nil, withLock({ process }) != nil, !isManaged {
                throw Failure.exited(withLock { errorText })
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw Failure.timedOut
    }

    private func start() throws {
        guard let launch else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launch.script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = launch.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        // Startup messages only: configuration problems, never email content.
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty, let self else { return }
            self.withLock { self.errorText = String((self.errorText + text).suffix(300)) }
        }
        try process.run()
        withLock {
            self.process = process
            errorText = ""
            lastActivity = Date()
        }
        logger.log("backend_started")
        scheduleIdleCheck()
    }

    private func scheduleIdleCheck() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.stopIfIdle() }
        withLock {
            idleTimer?.cancel()
            idleTimer = timer
        }
        timer.resume()
    }

    private func stopIfIdle() {
        let expired = withLock { Date().timeIntervalSince(lastActivity) > idleSeconds }
        if expired {
            logger.log("backend_idle_stop")
            stop()
        }
    }

    /// Stops the service only if this app started it.
    func stop() {
        let running = withLock { () -> Process? in
            idleTimer?.cancel()
            idleTimer = nil
            let current = process
            process = nil
            return current
        }
        guard let running, running.isRunning else { return }
        (running.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        running.terminate()
    }
}
