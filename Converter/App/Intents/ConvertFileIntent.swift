import AppIntents
import AppKit
import ConverterCore

/// "Convert File" in the Shortcuts app: files and a conversion in, the
/// results out, saved beside the originals like every other way in. For
/// folder automations and Quick Actions that don't need the wheel.
struct ConvertFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert File"
    static let description = IntentDescription(
        "Converts files with Swivel. Each result is saved next to its original; nothing is overwritten. Files the conversion doesn't apply to, and its own results, are skipped.",
        categoryName: "Files")

    @Parameter(title: "Files", description: "The files to convert.", supportedTypeIdentifiers: ["public.item"],
               requestValueDialog: "Which files?")
    var files: [IntentFile]

    @Parameter(title: "Conversion", description: "A format or tool from Swivel's wheel, such as JPEG or Resize › 1920 px.")
    var conversion: ConversionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$conversion)")
    }

    init() {}

    init(files: [IntentFile], conversion: ConversionEntity) {
        self.files = files
        self.conversion = conversion
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard let converter = await IntentSupport.converter(id: conversion.id) else {
            throw ConversionIntentError("\(conversion.name) isn't available on this Mac.")
        }
        // Unlike the wheel, which offers only what applies to every file, a
        // shortcut (a folder automation, say) gets whatever arrived: it
        // converts what it can and skips the rest.
        var convertible: [InputFile] = []
        var skipped: [String] = []
        for input in try IntentConversion.inputs(for: files) {
            if let reason = IntentConversion.reasonToSkip(input, with: converter) {
                skipped.append(reason)
            } else {
                convertible.append(input)
            }
        }
        guard !convertible.isEmpty else { throw ConversionIntentError(IntentConversion.summary(skipped)) }
        guard convertible.count >= converter.minimumInputs else {
            throw ConversionIntentError(IntentConversion.summary(
                ["\(converter.title) needs at least \(converter.minimumInputs) files."] + skipped))
        }
        let outputs = try await IntentConversion.run([.init(converter: converter, inputs: convertible)], skipped: skipped)
        return .result(value: outputs)
    }
}

/// A failure Shortcuts shows as is: the converter's own message.
struct ConversionIntentError: LocalizedError, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// What the intents take from the running app: its registry (ConverterCore's
/// converters plus the app's own) and the current settings.
enum IntentSupport {
    @MainActor static var registry: ConverterRegistry {
        (NSApp.delegate as? AppDelegate)?.registry ?? .standard
    }

    @MainActor static var options: ConversionOptions {
        (NSApp.delegate as? AppDelegate)?.settings.options ?? .default
    }

    /// Every conversion a shortcut may run: what this Mac can run, minus
    /// tools that open a window (Crop › Custom…).
    static func converters() async -> [any Converter] {
        await MainActor.run { registry.available.filter { !($0 is any InteractiveTool) } }
    }

    static func converter(id: String) async -> (any Converter)? {
        await converters().first { $0.id == id }
    }

    static func conversions() async -> [ConversionEntity] {
        await converters().map(ConversionEntity.init)
    }
}

/// Runs conversions for the intents the way the app's queue does: through
/// `JobRunner`, with the current settings, so results land beside the
/// originals and nothing is overwritten. `JobRunner` isn't tied to the
/// main actor, so the work runs off the main thread.
///
/// A shortcut is handed whatever files arrived, so files a conversion
/// doesn't apply to are skipped rather than failing the action, and so are
/// the conversion's own results: a folder automation would otherwise
/// convert each result again as it lands beside the original. The action
/// fails only when nothing at all was converted, saying why.
enum IntentConversion {
    /// A converter and the files it runs on (together, when it combines them).
    struct Job: Sendable {
        let converter: any Converter
        let inputs: [InputFile]
    }

    /// Runs every job and returns the results. A file a converter declines
    /// ("already well compressed") is skipped like one it doesn't apply
    /// to; `skipped` are the reasons for files already left out. Fails
    /// with every reason when nothing was converted, and with each
    /// converter's message when a conversion went wrong, once the other
    /// jobs are done.
    static func run(_ jobs: [Job], skipped: [String] = []) async throws -> [IntentFile] {
        let options = await IntentSupport.options
        var outputs: [IntentFile] = []
        var declined = skipped
        var failures: [String] = []
        for job in jobs {
            for outcome in await JobRunner.run(job.converter, on: job.inputs, options: options) {
                switch outcome {
                case .success(let url): outputs.append(result(at: url))
                case .failure(ConversionError.nothingToDo(let reason)): declined.append(reason)
                case .failure(let error): failures.append(error.localizedDescription)
                }
            }
        }
        guard failures.isEmpty else { throw ConversionIntentError(failures.joined(separator: "\n")) }
        guard !outputs.isEmpty else { throw ConversionIntentError(summary(declined)) }
        return outputs
    }

    /// Converts each file with the first of `ids` that applies to it, so
    /// "Compress" means `image.compress` for a photo and `video.compress`
    /// for a clip. `label` names the action in the message for a file none
    /// of them applies to.
    static func run(_ files: [IntentFile], firstOf ids: [String], label: String) async throws -> [IntentFile] {
        let available = await IntentSupport.converters()
        let candidates = ids.compactMap { id in available.first { $0.id == id } }
        var jobs: [Job] = []
        var skipped: [String] = []
        for input in try inputs(for: files) {
            let name = input.url.lastPathComponent
            guard let converter = candidates.first(where: { $0.accepts(input) }) else {
                skipped.append("\(label) doesn't apply to \(name).")
                continue
            }
            guard !isResult(input, of: converter) else {
                skipped.append(resultMessage(name, label: label))
                continue
            }
            jobs.append(Job(converter: converter, inputs: [input]))
        }
        return try await run(jobs, skipped: skipped)
    }

    /// Why `converter` should leave `input` alone, or nil to convert it.
    static func reasonToSkip(_ input: InputFile, with converter: any Converter) -> String? {
        let name = input.url.lastPathComponent
        guard converter.accepts(input) else {
            return converter.role == .format
                ? "\(converter.title) can't be made from \(name)."
                : "\(converter.title) doesn't apply to \(name)."
        }
        return isResult(input, of: converter) ? resultMessage(name, label: converter.title) : nil
    }

    /// Whether the file is named the way `converter` names its results:
    /// "photo (compressed).jpg" for Compress, or "photo (compressed) 2.jpg"
    /// when that name was taken. Conversions that only change the format
    /// add nothing to the name, and are left to `accepts` (a PNG isn't
    /// offered PNG).
    static func isResult(_ input: InputFile, of converter: any Converter) -> Bool {
        let suffix = converter.output(for: input).nameSuffix
        guard !suffix.isEmpty else { return false }
        var base = input.baseName
        if let number = base.range(of: #" [0-9]+$"#, options: .regularExpression) {
            base.removeSubrange(number)
        }
        return base.hasSuffix(suffix)
    }

    private static func resultMessage(_ name: String, label: String) -> String {
        "\(name) is already the result of \(label)."
    }

    /// Reasons, one per line, cut short when a folder's worth were skipped.
    static func summary(_ reasons: [String]) -> String {
        let limit = 6
        guard reasons.count > limit else { return reasons.joined(separator: "\n") }
        let shown = reasons.prefix(limit - 1)
        return (shown + ["…and \(reasons.count - shown.count) more."]).joined(separator: "\n")
    }

    /// Where files that aren't saved anywhere yet are written: a folder per
    /// run inside this one, which the app empties when it starts.
    static var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Swivel Shortcuts", isDirectory: true)
    }

    /// Empties `temporaryFolder` when the app starts; Shortcuts has long
    /// since passed on what was left there. Best effort.
    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryFolder)
    }

    /// The files as inputs. A file that isn't saved anywhere yet (made by
    /// an earlier action) is written to this run's folder in
    /// `temporaryFolder` first; its result lands there too, for Shortcuts
    /// to pass on.
    static func inputs(for files: [IntentFile]) throws -> [InputFile] {
        guard !files.isEmpty else { throw ConversionIntentError("No files to convert.") }
        let fm = FileManager.default
        var runFolder: URL?
        return try files.map { file in
            if let url = file.fileURL { return try InputFile(url: url) }
            let folder = runFolder ?? temporaryFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            runFolder = folder
            let name = file.filename.isEmpty ? "file" : file.filename
            var url = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                // Two files of one name in this run: each keeps its name.
                url = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
            return try InputFile(url: url)
        }
    }

    private static func result(at url: URL) -> IntentFile {
        IntentFile(fileURL: url, type: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
    }
}
