import Foundation
import os

/// Runs the system tools that ship with macOS (`ditto`, `tar`, `aa`,
/// `textutil`, `gzip`). Cancelling the calling task terminates the tool.
public enum Subprocess {
    public struct Output: Sendable {
        public var stdout: Data
        public var stderr: Data
    }

    /// Runs `executable` to completion and returns its output, or throws
    /// with the tool's last error line if it exits with a failure status.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], standardOutput: URL? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let collected = Collected()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in collected.appendError(handle.availableData) }

        var outputFile: FileHandle?
        if let standardOutput {
            FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
            outputFile = try FileHandle(forWritingTo: standardOutput)
            process.standardOutput = outputFile
        } else {
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            outputPipe.fileHandleForReading.readabilityHandler = { handle in collected.appendOutput(handle.availableData) }
        }
        defer { try? outputFile?.close() }

        let box = ProcessBox(process)
        try Task.checkCancellation()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ConversionError.encoderFailed("couldn't start \(executable): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            box.terminate()
        }
        errorPipe.fileHandleForReading.readabilityHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        // Pick up anything written just before exit.
        collected.appendError(errorPipe.fileHandleForReading.readDataToEndOfFile())
        if let pipe = process.standardOutput as? Pipe {
            collected.appendOutput(pipe.fileHandleForReading.readDataToEndOfFile())
        }

        try Task.checkCancellation()
        let output = collected.snapshot
        guard status == 0 else {
            let tool = (executable as NSString).lastPathComponent
            let message = String(decoding: output.stderr, as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? "exit status \(status)"
            throw ConversionError.encoderFailed("\(tool): \(message)")
        }
        return output
    }

    private final class ProcessBox: @unchecked Sendable {
        private let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    private final class Collected: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: Output(stdout: Data(), stderr: Data()))
        func appendOutput(_ data: Data) { state.withLock { $0.stdout.append(data) } }
        func appendError(_ data: Data) { state.withLock { $0.stderr.append(data) } }
        var snapshot: Output { state.withLock { $0 } }
    }
}
