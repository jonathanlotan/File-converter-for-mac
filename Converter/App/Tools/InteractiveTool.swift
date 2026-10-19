import ConverterCore
import Foundation

/// A tool that asks for its settings in a window before anything runs, like
/// Crop › Custom…. It's listed with the other conversions, but picking it
/// opens its window instead of starting a job.
protocol InteractiveTool: Converter {
    @MainActor func begin(with inputs: [InputFile])
}

extension JobQueue {
    /// Starts `converter` on `inputs`, or opens its window first when it
    /// needs settings.
    func start(_ converter: any Converter, on inputs: [InputFile]) {
        guard let tool = converter as? any InteractiveTool else {
            enqueue(converter, on: inputs)
            return
        }
        // After the drop or menu has finished, so the window comes up in front.
        Task { @MainActor in tool.begin(with: inputs) }
    }
}
