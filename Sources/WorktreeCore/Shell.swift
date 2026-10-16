import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let errors: String

    public var ok: Bool { status == 0 }
    public var text: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var errorText: String { errors.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum Shell {
    // Apps opened from Finder get a minimal PATH; Homebrew tools (gh, ccache) live in these folders.
    static let extraPath = ["/opt/homebrew/bin", "/usr/local/bin"]

    // Runs a command off the calling thread. Never throws: a failure to start is a failed result.
    public static func run(_ executable: String, _ arguments: [String], in directory: String? = nil, timeout: TimeInterval? = nil) async -> CommandResult {
        await withCheckedContinuation { continuation in
            // A thread of its own: waiting on a process must not hold one of Swift's few shared
            // task threads, or a scan running dozens of commands at once stalls itself.
            Thread.detachNewThread {
                continuation.resume(returning: runBlocking(executable, arguments, in: directory, timeout: timeout))
            }
        }
    }

    public static func git(_ arguments: [String], in directory: String, timeout: TimeInterval? = nil) async -> CommandResult {
        await run("git", ["-C", directory] + arguments, timeout: timeout)
    }

    public static func runBlocking(_ executable: String, _ arguments: [String], in directory: String? = nil, timeout: TimeInterval? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (extraPath + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // `git status` must not rewrite the index of a worktree another tool is using.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "", errors: error.localizedDescription)
        }
        let stopper = DispatchWorkItem { if process.isRunning { process.terminate() } }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stopper) }
        // Read standard error on another thread so a chatty command cannot fill one pipe and stall.
        let errors = DataBox()
        let reading = DispatchGroup()
        reading.enter()
        Thread.detachNewThread {
            errors.data = err.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        stopper.cancel()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            errors: String(decoding: errors.data, as: UTF8.self)
        )
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
