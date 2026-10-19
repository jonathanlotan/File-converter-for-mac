import Foundation

/// Finder-style output names: `photo.jpg`, then `photo 2.jpg`, `photo 3.jpg`, ...
public enum OutputNamer {
    /// The name to try on a given attempt (1 = no number).
    public static func name(base: String, suffix: String = "", fileExtension: String, attempt: Int) -> String {
        let stem = attempt <= 1 ? base + suffix : "\(base)\(suffix) \(attempt)"
        return fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
    }

    /// The first name that isn't taken in `folder` right now. Useful for
    /// showing the user where the output will go; `JobRunner` re-checks
    /// atomically when it moves the file into place.
    public static func firstAvailable(in folder: URL, base: String, spec: OutputSpec) -> URL {
        var attempt = 1
        while true {
            let candidate = folder.appendingPathComponent(
                name(base: base, suffix: spec.nameSuffix, fileExtension: spec.fileExtension, attempt: attempt),
                isDirectory: spec.isDirectory)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
    }
}
