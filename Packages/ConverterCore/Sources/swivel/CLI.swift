import ConverterCore
import Darwin
import Foundation

/// The `swivel` command: ConverterCore's conversions without the app.
@main
struct CLI {
    /// Kept in step with MARKETING_VERSION in Converter/project.yml (`make release` checks).
    static let version = "1.0.0"

    static let usage = """
    usage: swivel formats
           swivel list <file>...
           swivel convert --to <id> [--quality 0-1] [--compression-quality 0-1] [--no-metadata] <file>...
           swivel --version

      formats   every conversion and whether this Mac can do it
      list      conversions available for the given files
      convert   convert each file; the result is saved beside it (never overwritten)

    Press Ctrl-C during a conversion to cancel it; no partial file is left behind.
    """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { fail(usage, code: 2) }
        args.removeFirst()

        switch command {
        case "formats": printFormats()
        case "list": listConversions(for: args)
        case "convert": exit(await convert(args))
        case "-h", "--help", "help": print(usage)
        case "-v", "--version", "version": print("swivel \(version)")
        default: fail("unknown command '\(command)'\n\n\(usage)", code: 2)
        }
    }

    static func printFormats() {
        for converter in ConverterRegistry.standard.everything {
            let status = converter.isAvailable ? "" : "  (not available on this Mac)"
            print("\(converter.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(converter.title)\(status)")
        }
    }

    static func listConversions(for paths: [String]) {
        guard !paths.isEmpty else { fail(usage, code: 2) }
        let inputs = paths.map(loadInput)
        let converters = ConverterRegistry.standard.converters(for: inputs)
        if converters.isEmpty {
            print("No conversions available for \(paths.count == 1 ? "this file" : "all of these files").")
        }
        for role in [ConverterRole.format, .tool] {
            let group = converters.filter { $0.role == role }
            guard !group.isEmpty else { continue }
            print(role == .format ? "Formats:" : "Tools:")
            for converter in group {
                let example = inputs[0]
                let spec = converter.combinesInputs ? converter.output(for: inputs) : converter.output(for: example)
                let name = OutputNamer.name(base: spec.baseName ?? example.baseName, suffix: spec.nameSuffix,
                                            fileExtension: spec.fileExtension, attempt: 1)
                let marker = converter.isSecondary ? " (more)" : ""
                print("  \(converter.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(converter.title)\(marker)  → \(name)")
            }
        }
    }

    static func convert(_ arguments: [String]) async -> Int32 {
        var args = arguments
        var options = ConversionOptions()
        var converterID: String?
        var paths: [String] = []
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--to": converterID = args.isEmpty ? nil : args.removeFirst()
            case "--quality": options.imageQuality = parseFraction(args.isEmpty ? "" : args.removeFirst())
            case "--compression-quality": options.compressionQuality = parseFraction(args.isEmpty ? "" : args.removeFirst())
            case "--no-metadata": options.keepMetadata = false
            default:
                if arg.hasPrefix("--") { fail("unknown option '\(arg)'", code: 2) }
                paths.append(arg)
            }
        }
        guard let converterID, !paths.isEmpty else { fail(usage, code: 2) }
        guard let converter = ConverterRegistry.standard.converter(id: converterID) else {
            fail("unknown conversion '\(converterID)'. Run 'swivel formats' to see them all.", code: 2)
        }
        let inputs = paths.map(loadInput)

        let showProgress = isatty(STDERR_FILENO) != 0
        let job = Task {
            await JobRunner.run(converter, on: inputs, options: options) { fraction in
                guard showProgress else { return }
                let percent = Int((fraction * 100).rounded())
                FileHandle.standardError.write(Data("\r\(converter.title): \(percent)%  ".utf8))
            }
        }
        // Ctrl-C cancels the job instead of killing the process mid-write.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { job.cancel() }
        interrupt.resume()

        let results = await job.value
        interrupt.cancel()
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

        var failed = false
        var cancelled = false
        // A combining converter (archives) returns one result for all inputs.
        let labels = results.count == inputs.count
            ? inputs.map(\.url.lastPathComponent)
            : ["\(inputs.count) files"]
        for (label, result) in zip(labels, results) {
            switch result {
            case .success(let url):
                print("\(label) → \(url.lastPathComponent)")
            case .failure(let error) where error is CancellationError:
                cancelled = true
                print("\(label): cancelled")
            case .failure(let error):
                failed = true
                print("\(label): \(error.localizedDescription)")
            }
        }
        return cancelled ? 130 : (failed ? 1 : 0)
    }

    static func loadInput(_ path: String) -> InputFile {
        do {
            return try InputFile(url: URL(fileURLWithPath: path))
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    static func parseFraction(_ text: String) -> Double {
        guard let value = Double(text), (0...1).contains(value) else {
            fail("quality must be a number from 0 to 1", code: 2)
        }
        return value
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
