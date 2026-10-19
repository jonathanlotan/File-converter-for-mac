import AppIntents

/// Swivel's App Shortcuts: ready-made in the Shortcuts app and Spotlight,
/// each with its conversion fixed so there's nothing to set up. Spoken or
/// typed as "Convert to JPEG with Swivel".
struct SwivelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertToJPEGIntent(), phrases: ["Convert to JPEG with \(.applicationName)"],
                    shortTitle: "Convert to JPEG", systemImageName: "photo")
        AppShortcut(intent: CompressIntent(), phrases: ["Compress with \(.applicationName)"],
                    shortTitle: "Compress", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: ConvertToPDFIntent(), phrases: ["Convert to PDF with \(.applicationName)"],
                    shortTitle: "Convert to PDF", systemImageName: "doc.richtext")
    }
}

/// Images → JPEG, beside the originals.
struct ConvertToJPEGIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert to JPEG"
    static let description = IntentDescription("Saves a JPEG copy of each image next to the original.", categoryName: "Images")

    @Parameter(title: "Images", supportedTypeIdentifiers: ["public.image"], requestValueDialog: "Which images?")
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to JPEG")
    }

    init() {}

    init(files: [IntentFile]) {
        self.files = files
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentConversion.run(files, firstOf: ["image.jpeg"], label: "Convert to JPEG"))
    }
}

/// Smaller copies of images, videos, audio and PDFs, with the tool that fits each file.
struct CompressIntent: AppIntent {
    static let title: LocalizedStringResource = "Compress"
    static let description = IntentDescription(
        "Saves a smaller copy of each image, video, audio file or PDF next to the original, at the quality set in Swivel.",
        categoryName: "Files")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"], requestValueDialog: "Which files?")
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Compress \(\.$files)")
    }

    init() {}

    init(files: [IntentFile]) {
        self.files = files
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentConversion.run(
            files, firstOf: ["image.compress", "video.compress", "audio.compress", "pdf.compress"], label: "Compress"))
    }
}

/// Images and text documents → PDF, beside the originals.
struct ConvertToPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert to PDF"
    static let description = IntentDescription(
        "Saves a PDF of each image or document (text, RTF, HTML, Word, OpenDocument) next to the original.",
        categoryName: "Files")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"], requestValueDialog: "Which files?")
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to PDF")
    }

    init() {}

    init(files: [IntentFile]) {
        self.files = files
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentConversion.run(files, firstOf: ["image.pdf", "document.pdf"], label: "Convert to PDF"))
    }
}
