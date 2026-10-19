import Foundation

/// The list of conversions this system can perform. Every entry point (the
/// radial menu, the Open panel, Services, the CLI) asks the registry what can
/// be made from the files at hand.
public struct ConverterRegistry: Sendable {
    /// Every converter, including ones this system can't run.
    public let everything: [any Converter]
    /// Converters whose encoder exists on this system.
    public let available: [any Converter]

    public init(_ converters: [any Converter]) {
        everything = converters
        available = converters.filter(\.isAvailable)
    }

    public static let standard = ConverterRegistry(
        ImageConverters.all + MediaConverters.all + DocumentConverters.all + ArchiveConverters.all)

    public func converter(id: String) -> (any Converter)? {
        available.first { $0.id == id }
    }

    /// Converters that accept every one of `inputs`, in menu order.
    public func converters(for inputs: [InputFile]) -> [any Converter] {
        guard !inputs.isEmpty else { return [] }
        return available.filter { converter in
            inputs.count >= converter.minimumInputs && inputs.allSatisfy(converter.accepts)
        }
    }
}
