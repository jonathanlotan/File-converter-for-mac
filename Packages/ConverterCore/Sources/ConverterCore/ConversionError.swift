import Foundation

public enum ConversionError: LocalizedError, Sendable, Equatable {
    case unreadableInput(URL)
    case unsupported(String)
    case encoderFailed(String)
    case nothingToDo(String)
    case destinationNotWritable(URL, reason: String)
    case outputMissing

    public var errorDescription: String? {
        switch self {
        case .unreadableInput(let url):
            return "Couldn't read \(url.lastPathComponent)."
        case .unsupported(let message):
            return message
        case .encoderFailed(let message):
            return "Conversion failed: \(message)"
        case .nothingToDo(let message):
            return message
        case .destinationNotWritable(let folder, let reason):
            return "Couldn't save in \(folder.lastPathComponent): \(reason)"
        case .outputMissing:
            return "The conversion finished without producing a file."
        }
    }
}
