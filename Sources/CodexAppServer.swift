import Darwin
import Foundation

enum CodexAppServerError: LocalizedError, Equatable {
    case notInstalled
    case launchFailed
    case exitedBeforeResponse
    case timedOut(seconds: Int)
    case rpcError(code: Int?)
    case invalidResponse
    case responseTooLarge
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Codex app-server is unavailable: the codex CLI could not be found."
        case .launchFailed:
            return "Codex app-server is unavailable: it could not be started."
        case .exitedBeforeResponse:
            return "Codex app-server exited before returning usage."
        case .timedOut(let seconds):
            return "Codex app-server did not respond within \(seconds) seconds."
        case .rpcError(let code):
            if let code {
                return "Codex app-server rejected the usage request (code \(code))."
            }
            return "Codex app-server rejected the usage request."
        case .invalidResponse:
            return "Codex app-server returned an unexpected response."
        case .responseTooLarge:
            return "Codex app-server returned an oversized response."
        case .readFailed:
            return "Could not read from Codex app-server."
        case .writeFailed:
            return "Could not send a request to Codex app-server."
        }
    }
}

enum CodexAppServerClient {
    static let defaultTimeout: TimeInterval = 10

    static func fetchRateLimits(timeout: TimeInterval = defaultTimeout) async throws -> CodexRateLimitSnapshot {
        try await Task.detached(priority: .utility) {
            try fetchSync(timeout: timeout)
        }.value
    }

    private static func fetchSync(timeout: TimeInterval) throws -> CodexRateLimitSnapshot {
        guard let executable = codexExecutable() else {
            throw CodexAppServerError.notInstalled
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]

        // A Finder-launched app gets a minimal PATH. codex's Node launcher needs
        // node, so include the CLI's own directory and standard package prefixes.
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let executableDirectory = executable.deletingLastPathComponent().path
        environment["PATH"] = [
            executableDirectory,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            existingPath,
        ].joined(separator: ":")
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed
        }

        let deadline = Date().addingTimeInterval(timeout)
        let timeoutState = TimeoutState()
        let timeoutWork = DispatchWorkItem {
            // The installed `codex` is a Node launcher that spawns the native
            // binary. Collect descendants before signalling so an orphan cannot
            // keep the stdout pipe open and defeat the deadline.
            let descendants = descendantPIDs(of: process.processIdentifier)
            timeoutState.markTimedOut()
            for child in descendants {
                kill(child, SIGKILL)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        defer {
            timeoutWork.cancel()
            shutdown(process, input: input.fileHandleForWriting)
        }

        let reader = LineReader(handle: output.fileHandleForReading)
        try send(
            [
                [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "clientInfo": [
                            "name": "codex-reset-tray",
                            "title": "Codex Reset Tray",
                            "version": AppBuildInfo.version,
                        ],
                        "capabilities": [
                            "experimentalApi": false,
                            "requestAttestation": false,
                        ],
                    ],
                ]
            ],
            to: input.fileHandleForWriting
        )
        _ = try waitForResponse(
            id: 1,
            reader: reader,
            timeoutState: timeoutState,
            deadline: deadline,
            timeout: timeout
        )

        try send(
            [
                ["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()],
                [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "account/rateLimits/read",
                    "params": ["excludeResetCreditDetails": true],
                ],
            ],
            to: input.fileHandleForWriting
        )
        let result = try waitForResponse(
            id: 2,
            reader: reader,
            timeoutState: timeoutState,
            deadline: deadline,
            timeout: timeout
        )
        return try CodexRateLimitsParser.parse(root: result, observedAt: Date())
    }

    private static func waitForResponse(
        id: Int,
        reader: LineReader,
        timeoutState: TimeoutState,
        deadline: Date,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        while true {
            let line: String?
            do {
                line = try reader.nextLine()
            } catch {
                if timeoutState.isTimedOut || Date() >= deadline {
                    throw CodexAppServerError.timedOut(seconds: Int(timeout))
                }
                throw CodexAppServerError.exitedBeforeResponse
            }
            guard let line else {
                if timeoutState.isTimedOut || Date() >= deadline {
                    throw CodexAppServerError.timedOut(seconds: Int(timeout))
                }
                throw CodexAppServerError.exitedBeforeResponse
            }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let message = object as? [String: Any] else {
                continue
            }
            guard let responseID = message["id"] as? NSNumber, responseID.intValue == id else {
                continue
            }
            if let error = message["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue
                throw CodexAppServerError.rpcError(code: code)
            }
            guard let result = message["result"] as? [String: Any] else {
                throw CodexAppServerError.invalidResponse
            }
            return result
        }
    }

    private static func send(_ objects: [[String: Any]], to handle: FileHandle) throws {
        var payload = Data()
        for object in objects {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else {
                throw CodexAppServerError.invalidResponse
            }
            payload.append(data)
            payload.append(0x0A)
        }
        do {
            try handle.write(contentsOf: payload)
        } catch {
            throw CodexAppServerError.writeFailed
        }
    }

    private static func shutdown(_ process: Process, input: FileHandle) {
        try? input.close()
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func descendantPIDs(of root: Int32) -> [Int32] {
        var descendants: [Int32] = []
        var pending = [root]
        while let parent = pending.popLast() {
            for child in directChildPIDs(of: parent) {
                descendants.append(child)
                pending.append(child)
            }
        }
        return descendants
    }

    private static func directChildPIDs(of parent: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(parent)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int32($0) }
    }

    private static func codexExecutable() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CODEX_BINARY"],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":") {
            let path = "\(directory)/codex"
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

private final class TimeoutState {
    private let lock = NSLock()
    private var timedOut = false

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

private final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private let maximumLineBytes = 8 * 1_024 * 1_024

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                return line
            }

            var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = read(handle.fileDescriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw CodexAppServerError.readFailed
            }
            if count == 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > maximumLineBytes {
                throw CodexAppServerError.responseTooLarge
            }
        }
    }
}
