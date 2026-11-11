import Foundation

typealias JSON = [String: Any]

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Lets the UI stop a running engine command.
final class EngineHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false

    func attach(_ p: Process) { lock.lock(); process = p; let c = cancelled; lock.unlock(); if c { p.terminate() } }
    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

/// Runs the bundled `gatepass-engine` binary and speaks its JSON-lines protocol.
enum Engine {
    static var binaryURL: URL {
        if let override = ProcessInfo.processInfo.environment["GATEPASS_ENGINE"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "gatepass-engine") {
            return bundled
        }
        // Running from `swift run` during development.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../engine/target/release/gatepass-engine")
            .standardized
    }

    /// Runs one engine command.
    /// - Parameters:
    ///   - input: optional first line written to stdin (e.g. credentials).
    ///   - onEvent: called on the main actor for every non-final event (progress etc.).
    ///   - onPrompt: called when the engine needs an answer; the return value is written to stdin.
    /// - Returns: the final event (`done`, `devices`, `apps`, …).
    @discardableResult
    static func run(
        _ args: [String],
        input: String? = nil,
        handle: EngineHandle? = nil,
        onEvent: @escaping @MainActor (JSON) -> Void = { _ in },
        onPrompt: @escaping @MainActor (JSON) async -> String = { _ in "" }
    ) async throws -> JSON {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["RUST_LOG"] = env["RUST_LOG"] ?? "info"
        // Default "local": sign-in identity comes from this Mac; no third-party anisette server.
        let anisette = UserDefaults.standard.string(forKey: Pref.anisette) ?? "local"
        env["GATEPASS_ANISETTE"] = ["local", "auto", "remote"].contains(anisette) ? anisette : "local"
        if UserDefaults.standard.bool(forKey: Pref.keychain) { env["GATEPASS_KEYCHAIN"] = "1" }
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain stderr continuously so a chatty engine can never block on a full pipe.
        let errLog = LogBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errLog.append(handle.availableData)
        }

        do { try process.run() } catch {
            throw EngineError(message: "Can't start the engine (\(binaryURL.path)): \(error.localizedDescription)")
        }
        handle?.attach(process)

        let writer = stdin.fileHandleForWriting
        func send(_ line: String) {
            try? writer.write(contentsOf: Data((line + "\n").utf8))
        }
        if let input { send(input) }

        var final: JSON?
        var errorMessage: String?

        for try await line in stdout.fileHandleForReading.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? JSON,
                  let type = event["type"] as? String else { continue }

            switch type {
            case "progress", "cancellable":
                await onEvent(event)
            case "prompt":
                let answer = await onPrompt(event)
                send(answer)
            case "error":
                errorMessage = event["message"] as? String ?? "Unknown error"
            default:
                final = event
            }
        }

        process.waitUntilExit()
        try? writer.close()
        stderr.fileHandleForReading.readabilityHandler = nil
        EngineLog.write(command: args.first ?? "", status: process.terminationStatus, log: errLog.text, error: errorMessage)

        if handle?.cancelled == true { throw CancellationError() }
        if let errorMessage { throw EngineError(message: errorMessage) }
        if let final { return final }
        let err = errLog.text.suffix(800)
        throw EngineError(message: err.isEmpty ? "The engine stopped unexpectedly (code \(process.terminationStatus))." : String(err))
    }
}

/// Appends each engine run to ~/Library/Logs/GatePass/engine.log (skips the 30-second polling noise).
enum EngineLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GatePass")
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let file = dir.appendingPathComponent("engine.log")
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Keep the log small: start over once it passes 2 MB.
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 2_000_000 {
            try? Data().write(to: file)
        }
        return file
    }()

    static func write(command: String, status: Int32, log: String, error: String?) {
        if ["devices", "apps", "accounts", "ipa-info"].contains(command), status == 0 { return }
        var entry = "\n=== \(Date()) · \(command) · exit \(status) ===\n\(log)"
        if let error { entry += "ERROR: \(error)\n" }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }
}

final class LogBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
