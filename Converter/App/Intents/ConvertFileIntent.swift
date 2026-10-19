import AppIntents
import AppKit
import ConverterCore

/// "Convert File" in the Shortcuts app: files and a conversion in, the
/// results out, saved beside the originals like every other way in. For
/// folder automations and Quick Actions that don't need the wheel.
struct ConvertFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert File"
    static let description = IntentDescription(
        "Converts files with Swivel. Each result is saved next to its original; nothing is overwritten.",
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
        let inputs = try IntentConversion.inputs(for: files)
        // The wheel's rule: the conversion has to apply to every file.
        if let odd = inputs.first(where: { !converter.accepts($0) }) {
            let name = odd.url.lastPathComponent
            throw ConversionIntentError(converter.role == .format
                ? "\(converter.title) can't be made from \(name)."
                : "\(converter.title) doesn't apply to \(name).")
        }
        guard inputs.count >= converter.minimumInputs else {
            throw ConversionIntentError("\(converter.title) needs at least \(converter.minimumInputs) files.")
        }
        let outputs = try await IntentConversion.run([.init(converter: converter, inputs: inputs)])
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
enum IntentConversion {
    /// A converter and the files it runs on (together, when it combines them).
    struct Job: Sendable {
        let converter: any Converter
        let inputs: [InputFile]
    }

    /// Runs every job and returns the results. Any failure fails the whole
    /// action with each converter's message, once the other jobs are done.
    static func run(_ jobs: [Job]) async throws -> [IntentFile] {
        let options = await IntentSupport.options
        var outputs: [IntentFile] = []
        var failures: [String] = []
        for job in jobs {
            for outcome in await JobRunner.run(job.converter, on: job.inputs, options: options) {
                switch outcome {
                case .success(let url): outputs.append(result(at: url))
                case .failure(let error): failures.append(error.localizedDescription)
                }
            }
        }
        guard failures.isEmpty else { throw ConversionIntentError(failures.joined(separator: "\n")) }
        return outputs
    }

    /// Converts each file with the first of `ids` that applies to it, so
    /// "Compress" means `image.compress` for a photo and `video.compress`
    /// for a clip. `label` names the action in the message for a file none
    /// of them applies to.
    static func run(_ files: [IntentFile], firstOf ids: [String], label: String) async throws -> [IntentFile] {
        let available = await IntentSupport.converters()
        let candidates = ids.compactMap { id in available.first { $0.id == id } }
        let jobs = try inputs(for: files).map { input in
            guard let converter = candidates.first(where: { $0.accepts(input) }) else {
                throw ConversionIntentError("\(label) doesn't apply to \(input.url.lastPathComponent).")
            }
            return Job(converter: converter, inputs: [input])
        }
        return try await run(jobs)
    }

    /// The files as inputs. A file that isn't saved anywhere yet (made by
    /// an earlier action) is written to a temporary folder first; its
    /// result lands there too, for Shortcuts to pass on.
    static func inputs(for files: [IntentFile]) throws -> [InputFile] {
        guard !files.isEmpty else { throw ConversionIntentError("No files to convert.") }
        return try files.map { file in
            if let url = file.fileURL { return try InputFile(url: url) }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Swivel-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(file.filename.isEmpty ? "file" : file.filename)
            try file.data.write(to: url)
            return try InputFile(url: url)
        }
    }

    private static func result(at url: URL) -> IntentFile {
        IntentFile(fileURL: url, type: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
    }
}
