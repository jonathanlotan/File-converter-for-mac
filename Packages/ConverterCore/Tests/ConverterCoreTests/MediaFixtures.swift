import AVFoundation
import CoreText
import Foundation
@testable import ConverterCore

/// What a generated sample should contain.
struct SampleFile: CustomStringConvertible {
    enum Kind { case video, audio, document, pdf, archive }

    let url: URL
    let kind: Kind
    var duration: Double = 0
    var width = 0
    var height = 0
    var hasAudio = false
    var bitsPerSample = 16
    var pages = 0
    /// Relative paths and contents an archive extracts to.
    var archiveContents: [String: String] = [:]

    var name: String { url.lastPathComponent }
    var description: String { name }
}

/// Builds video, audio, document, PDF and archive samples with AVFoundation,
/// Core Text and the system tools. Nothing is downloaded.
enum MediaSamples {
    static let phrase = "Converter sample document"

    static func makeAll(in folder: URL) async throws -> [SampleFile] {
        var samples: [SampleFile] = []
        let fm = FileManager.default
        let scratch = folder.appendingPathComponent(".scratch", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        // Audio: a 1.5 s stereo tone, 16-bit and 24-bit.
        let wav = folder.appendingPathComponent("tone.wav")
        try writeTone(to: wav, seconds: 1.5, bits: 16)
        samples.append(SampleFile(url: wav, kind: .audio, duration: 1.5))
        let wav24 = folder.appendingPathComponent("tone24.wav")
        try writeTone(to: wav24, seconds: 1.5, bits: 24)
        samples.append(SampleFile(url: wav24, kind: .audio, duration: 1.5, bitsPerSample: 24))
        for (name, args) in [("tone.m4a", ["-f", "m4af", "-d", "aac"]), ("tone-lossless.m4a", ["-f", "m4af", "-d", "alac"]),
                             ("tone.aiff", ["-f", "AIFF", "-d", "BEI16"]), ("tone.flac", ["-f", "flac", "-d", "flac"]),
                             ("tone.caf", ["-f", "caff", "-d", "LEI16"]), ("tone.aac", ["-f", "adts", "-d", "aac"])] {
            let url = folder.appendingPathComponent(name)
            try await Subprocess.run("/usr/bin/afconvert", args + [wav.path, url.path])
            samples.append(SampleFile(url: url, kind: .audio, duration: 1.5))
        }

        // Video: 2 s of 320×240 H.264, with and without sound.
        let silent = folder.appendingPathComponent("silent.mov")
        try await writeVideo(to: silent, width: 320, height: 240, seconds: 2)
        samples.append(SampleFile(url: silent, kind: .video, duration: 2, width: 320, height: 240))
        let longTone = scratch.appendingPathComponent("tone2s.wav")
        try writeTone(to: longTone, seconds: 2, bits: 16)
        let aacTone = scratch.appendingPathComponent("tone2s.m4a")
        try await Subprocess.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", longTone.path, aacTone.path])
        for (name, type) in [("clip.mov", AVFileType.mov), ("clip.mp4", .mp4)] {
            let url = folder.appendingPathComponent(name)
            try await mux(video: silent, audio: aacTone, to: url, fileType: type)
            samples.append(SampleFile(url: url, kind: .video, duration: 2, width: 320, height: 240, hasAudio: true))
        }

        // Documents: plain text, then textutil's other formats from it.
        let text = folder.appendingPathComponent("sample.txt")
        try "\(phrase)\n\nA second paragraph, with ünïcödé.\n".write(to: text, atomically: true, encoding: .utf8)
        samples.append(SampleFile(url: text, kind: .document))
        for ext in ["rtf", "html", "docx", "doc", "odt"] {
            let url = folder.appendingPathComponent("sample.\(ext)")
            try await Subprocess.run("/usr/bin/textutil", ["-convert", ext, "-output", url.path, text.path])
            samples.append(SampleFile(url: url, kind: .document))
        }
        let markdown = folder.appendingPathComponent("notes.md")
        try "# \(phrase)\n\nSome *Markdown* text.\n".write(to: markdown, atomically: true, encoding: .utf8)
        samples.append(SampleFile(url: markdown, kind: .document))

        // PDFs: three Letter pages with real text, and a single page.
        let pdf = folder.appendingPathComponent("report.pdf")
        try writePDF(to: pdf, pages: 3)
        samples.append(SampleFile(url: pdf, kind: .pdf, pages: 3))
        let onePage = folder.appendingPathComponent("memo.pdf")
        try writePDF(to: onePage, pages: 1)
        samples.append(SampleFile(url: onePage, kind: .pdf, pages: 1))

        // Archives of a small folder tree.
        let tree = ["a.txt": "alpha", "b.txt": "bravo", "sub/c.txt": "charlie"]
        let bundle = scratch.appendingPathComponent("bundle", isDirectory: true)
        for (path, content) in tree {
            let url = bundle.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        func archive(_ name: String, _ tool: String, _ args: [String]) async throws {
            try await Subprocess.run(tool, args)
            samples.append(SampleFile(url: folder.appendingPathComponent(name), kind: .archive, archiveContents: tree))
        }
        // bundle.zip holds the folder itself ("bundle/a.txt"); extraction must not nest it twice.
        try await archive("bundle.zip", "/usr/bin/ditto", ["-c", "-k", "--keepParent", bundle.path, folder.appendingPathComponent("bundle.zip").path])
        try await archive("bundle.tar.gz", "/usr/bin/tar", ["-czf", folder.appendingPathComponent("bundle.tar.gz").path, "-C", bundle.path, "a.txt", "b.txt", "sub"])
        try await archive("bundle.7z", "/usr/bin/tar", ["--format", "7zip", "-cf", folder.appendingPathComponent("bundle.7z").path, "-C", bundle.path, "a.txt", "b.txt", "sub"])
        try await archive("bundle.aar", "/usr/bin/aa", ["archive", "-d", bundle.path, "-o", folder.appendingPathComponent("bundle.aar").path])
        let gz = folder.appendingPathComponent("notes.txt.gz")
        try await Subprocess.run("/usr/bin/gzip", ["-c", text.path], standardOutput: gz)
        samples.append(SampleFile(url: gz, kind: .archive, archiveContents: ["": try String(contentsOf: text, encoding: .utf8)]))

        try fm.removeItem(at: scratch)
        return samples
    }

    // MARK: - Builders

    static func writeTone(to url: URL, seconds: Double, bits: Int, rate: Double = 44_100) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.4) }
        }
        try file.write(from: buffer)
    }

    /// `noisy` fills frames with random pixels at a high bit rate: footage
    /// that a re-encode can really shrink.
    static func writeVideo(to url: URL, width: Int, height: Int, seconds: Double, fps: Int32 = 30,
                           noisy: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if noisy { settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 20_000_000] }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ConversionError.encoderFailed("video fixture") }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { throw ConversionError.encoderFailed("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let shade = UInt8(index * 255 / max(frames - 1, 1))
            var seed = UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * stride + x * 4
                    if noisy {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        let v = UInt8(truncatingIfNeeded: seed >> 56)
                        p[0] = v; p[1] = v &+ 85; p[2] = v &+ 170; p[3] = 255
                    } else {
                        p[0] = x < width / 2 ? 255 : shade; p[1] = shade; p[2] = 255 - shade; p[3] = 255 // BGRA
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: fps))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.encoderFailed("video fixture") }
    }

    /// Puts a video track and an audio track into one movie without re-encoding.
    static func mux(video: URL, audio: URL, to url: URL, fileType: AVFileType) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let range = CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: videoTrack, at: .zero)
        let audioRange = CMTimeRange(start: .zero, duration: min(range.duration, try await audioAsset.load(.duration)))
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(audioRange, of: audioTrack, at: .zero)
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        session.outputURL = url
        session.outputFileType = fileType
        try await ExportSessionRunner(session).run { _ in }
    }

    static func writePDF(to url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ConversionError.encoderFailed("pdf fixture") }
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for page in 1...pages {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: "Page \(page) of the \(phrase)",
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A white image with a line of black text, for text recognition.
    static func textImage(_ text: String, width: Int = 1600, height: Int = 300) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]))
        context.textPosition = CGPoint(x: 60, y: 120)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    /// A one-page PDF holding a large, noisy (barely compressible) image.
    static func writeImagePDF(to url: URL, side: Int = 1500) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt64 = 42
        for i in 0..<(context.bytesPerRow * side) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        let image = context.makeImage()!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: CGRect(x: 56, y: 146, width: 500, height: 500))
        pdf.endPDFPage()
        pdf.closePDF()
    }
}
