import Darwin
import Foundation

/// Runs converters with the guarantees every entry point relies on:
///
/// - The converter writes into a temporary folder on the same volume as the
///   original, never beside it directly.
/// - On success the result is renamed into place with `RENAME_EXCL`, so an
///   existing file is never overwritten; a taken name moves on to `name 2`,
///   `name 3`, ...
/// - On failure or cancellation the temporary folder is deleted, so no
///   partial file is left behind.
/// - The original is only ever read.
public enum JobRunner {
    /// Converts one file. The result goes beside it.
    @discardableResult
    public static func run(
        _ converter: any Converter,
        on input: InputFile,
        options: ConversionOptions = .default,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> URL {
        guard converter.accepts(input) else {
            throw ConversionError.unsupported("\(converter.title) can't be made from \(input.url.lastPathComponent).")
        }
        return try await perform(spec: converter.output(for: input), beside: input) { destination in
            try await converter.convert(input, to: destination, options: options, progress: progress)
        } progress: { progress($0) }
    }

    /// Converts several files into one output (for converters that combine
    /// inputs). The result goes beside the first file.
    @discardableResult
    public static func runCombined(
        _ converter: any Converter,
        on inputs: [InputFile],
        options: ConversionOptions = .default,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> URL {
        guard let first = inputs.first else { throw ConversionError.nothingToDo("No files to convert.") }
        guard converter.combinesInputs || inputs.count == 1 else {
            throw ConversionError.unsupported("\(converter.title) converts one file at a time.")
        }
        guard inputs.allSatisfy(converter.accepts) else {
            throw ConversionError.unsupported("\(converter.title) can't be made from all of these files.")
        }
        return try await perform(spec: converter.output(for: inputs), beside: first) { destination in
            try await converter.convert(inputs, to: destination, options: options, progress: progress)
        } progress: { progress($0) }
    }

    /// Converts several files: one combined output when the converter
    /// combines inputs, otherwise one output per file. Each output succeeds
    /// or fails on its own; overall progress is reported across all of them.
    public static func run(
        _ converter: any Converter,
        on inputs: [InputFile],
        options: ConversionOptions = .default,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> [Result<URL, any Error>] {
        if converter.combinesInputs && inputs.count > 1 {
            do {
                return [.success(try await runCombined(converter, on: inputs, options: options, progress: progress))]
            } catch {
                return [.failure(error)]
            }
        }
        var results: [Result<URL, any Error>] = []
        for (index, input) in inputs.enumerated() {
            if Task.isCancelled {
                results.append(.failure(CancellationError()))
                continue
            }
            let share = 1.0 / Double(inputs.count)
            let offset = Double(index) * share
            do {
                let url = try await run(converter, on: input, options: options) { fraction in
                    progress(offset + fraction * share)
                }
                results.append(.success(url))
            } catch {
                results.append(.failure(error))
            }
        }
        progress(1)
        return results
    }

    // MARK: - Shared steps

    private static func perform(
        spec: OutputSpec,
        beside input: InputFile,
        convert: (URL) async throws -> Void,
        progress: ProgressHandler
    ) async throws -> URL {
        let folder = input.url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw ConversionError.destinationNotWritable(folder, reason: "the folder is read-only")
        }
        let base = spec.baseName ?? input.baseName

        let workFolder = try makeWorkFolder(near: folder)
        defer { try? FileManager.default.removeItem(at: workFolder) }

        let staged = workFolder.appendingPathComponent(
            OutputNamer.name(base: base, suffix: spec.nameSuffix, fileExtension: spec.fileExtension, attempt: 1),
            isDirectory: spec.isDirectory)

        progress(0)
        try Task.checkCancellation()
        try await convert(staged)
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw ConversionError.outputMissing
        }
        let placed = try moveIntoPlace(staged, folder: folder, base: base, spec: spec)
        progress(1)
        return placed
    }

    static func makeWorkFolder(near folder: URL) throws -> URL {
        let fm = FileManager.default
        if let url = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true) {
            return url
        }
        // Some volumes (network shares, FAT) have no replacement directory.
        // Fall back to a hidden folder beside the output.
        let hidden = folder.appendingPathComponent(".converter-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: hidden, withIntermediateDirectories: false)
            return hidden
        } catch {
            throw ConversionError.destinationNotWritable(folder, reason: error.localizedDescription)
        }
    }

    static func moveIntoPlace(_ staged: URL, folder: URL, base: String, spec: OutputSpec) throws -> URL {
        for attempt in 1...10_000 {
            let candidate = folder.appendingPathComponent(
                OutputNamer.name(base: base, suffix: spec.nameSuffix, fileExtension: spec.fileExtension, attempt: attempt),
                isDirectory: spec.isDirectory)
            if renamex_np(staged.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            let code = errno
            switch code {
            case EEXIST:
                continue
            case EXDEV:
                // Work folder ended up on another volume: copy instead.
                // copyItem refuses to overwrite, like RENAME_EXCL.
                do {
                    try FileManager.default.copyItem(at: staged, to: candidate)
                    return candidate
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                } catch {
                    try? FileManager.default.removeItem(at: candidate)
                    throw ConversionError.destinationNotWritable(folder, reason: error.localizedDescription)
                }
            default:
                throw ConversionError.destinationNotWritable(folder, reason: String(cString: strerror(code)))
            }
        }
        throw ConversionError.destinationNotWritable(folder, reason: "too many files with the same name")
    }
}
