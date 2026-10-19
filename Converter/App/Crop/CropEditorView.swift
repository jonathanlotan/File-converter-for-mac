import AppKit
import Combine
import ConverterCore
import SwiftUI

/// Opens the crop editor in its own window. Each crop is saved beside its
/// original like any other conversion, through the job queue.
@MainActor
final class CropEditorController: NSObject, NSWindowDelegate {
    private let queue: JobQueue
    private var window: NSWindow?
    private(set) var model: CropEditorModel?
    private var title: AnyCancellable?
    /// False in tests, so no window appears.
    var showsWindow = true

    init(queue: JobQueue) {
        self.queue = queue
    }

    func open(_ inputs: [InputFile]) {
        let images = inputs.filter { $0.image != nil }
        guard !images.isEmpty else { return }
        let model = CropEditorModel(inputs: images, loadsPreviews: showsWindow)
        model.onCrop = { [weak self] converter, input in self?.queue.enqueue(converter, on: [input]) }
        model.onFinish = { [weak self] in self?.finish() }
        self.model = model
        guard showsWindow else { return }

        let window = self.window ?? makeWindow()
        self.window = window
        window.contentView = NSHostingView(rootView: CropEditorView(model: model))
        title = model.$index.sink { [weak window] index in
            window?.title = "Crop “\(images[index].url.lastPathComponent)”"
            window?.subtitle = images.count > 1 ? "\(index + 1) of \(images.count)" : ""
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        model = nil
        title = nil
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 740, height: 440)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ConverterCropEditor")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
        title = nil
    }
}

/// The image with the crop drawn over it, and the controls underneath.
struct CropEditorView: View {
    @ObservedObject var model: CropEditorModel

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                CropCanvas(model: model, area: geometry.size)
            }
            .padding(24)
            .background(Color(white: 0.11))
            .environment(\.colorScheme, .dark)
            Divider()
            controls
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Aspect", selection: Binding(get: { model.aspect }, set: { model.setAspect($0) })) {
                ForEach(model.aspectChoices) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .fixedSize()

            HStack(spacing: 4) {
                Text("Size")
                TextField("Width", value: Binding(get: { model.resultSize.width }, set: { model.setOutputWidth($0) }),
                          format: .number.grouping(.never))
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Width in pixels")
                Text("×").foregroundStyle(.secondary)
                TextField("Height", value: Binding(get: { model.resultSize.height }, set: { model.setOutputHeight($0) }),
                          format: .number.grouping(.never))
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Height in pixels")
                Text("px").foregroundStyle(.secondary)
                if model.outputSize != nil {
                    Button { model.setOutputSize(nil) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Save the crop at its own size instead of scaling it")
                }
            }
            .fixedSize()
            .help("Type a size to save the crop scaled to exactly that many pixels")

            Spacer(minLength: 8)

            Button("Reset") { model.reset() }
                .disabled(model.isUnchanged)
            if model.inputs.count > 1 {
                Button("Skip") { model.skip() }
                    .help("Leave this image as it is and show the next one")
            }
            Button("Cancel", role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button(model.hasMore ? "Crop & Next" : "Crop") { model.crop() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isUnchanged)
        }
    }
}

/// The picture fitted to the space, the area outside the crop dimmed, a
/// rule-of-thirds grid, and handles to drag.
private struct CropCanvas: View {
    @ObservedObject var model: CropEditorModel
    let area: CGSize
    @State private var dragging = false

    /// Where the image sits in the canvas.
    private var imageFrame: CGRect {
        let size = model.imageSize
        let scale = min(area.width / CGFloat(size.width), area.height / CGFloat(size.height))
        let w = CGFloat(size.width) * scale, h = CGFloat(size.height) * scale
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    /// View points per image pixel.
    private var scale: CGFloat { imageFrame.width / CGFloat(model.imageSize.width) }

    private var cropFrame: CGRect {
        let r = model.region, f = imageFrame
        return CGRect(x: f.minX + CGFloat(r.x) * scale, y: f.minY + CGFloat(r.y) * scale,
                      width: CGFloat(r.width) * scale, height: CGFloat(r.height) * scale)
    }

    var body: some View {
        let image = imageFrame, crop = cropFrame
        ZStack(alignment: .topLeading) {
            picture
                .frame(width: image.width, height: image.height)
                .offset(x: image.minX, y: image.minY)

            // Dim everything outside the crop.
            Path { path in
                path.addRect(image)
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            grid(in: crop)
                .stroke(Color.white.opacity(dragging ? 0.55 : 0.28), lineWidth: 0.5)
                .allowsHitTesting(false)
            Path { $0.addRect(crop) }
                .stroke(Color.white, lineWidth: 1)
                .allowsHitTesting(false)

            // Drag inside the crop to move it.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)
                .gesture(drag(.move))
                .moveCursor()

            ForEach(CropEditorModel.Handle.allCases.filter { $0 != .move }, id: \.self) { handle in
                handleView(handle, in: crop)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop area")
        .accessibilityValue("\(model.region.width) by \(model.region.height) pixels")
    }

    @ViewBuilder private var picture: some View {
        if let preview = model.preview {
            Image(decorative: preview, scale: 1).resizable().interpolation(.high)
        } else if let image = NSImage(contentsOf: model.input.url) {
            Image(nsImage: image).resizable()
        } else {
            Rectangle().fill(Color.gray.opacity(0.3))
        }
    }

    private func grid(in rect: CGRect) -> Path {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }

    private func drag(_ handle: CropEditorModel.Handle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                dragging = true
                model.drag(handle, by: CGSize(width: value.translation.width / scale,
                                              height: value.translation.height / scale))
            }
            .onEnded { _ in
                dragging = false
                model.endDrag()
            }
    }

    /// Corner brackets and edge bars, each with a larger invisible target.
    private func handleView(_ handle: CropEditorModel.Handle, in rect: CGRect) -> some View {
        let point = Self.position(of: handle, in: rect)
        let target: CGFloat = 26
        return HandleMark(handle: handle)
            .frame(width: target, height: target)
            .contentShape(Rectangle())
            .offset(x: point.x - target / 2, y: point.y - target / 2)
            .gesture(drag(handle))
            .resizeCursor(for: handle)
    }

    static func position(of handle: CropEditorModel.Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .move: return CGPoint(x: rect.midX, y: rect.midY)
        }
    }
}

/// A thick white L at a corner, or a short bar on an edge, drawn on the
/// crop's border.
private struct HandleMark: View {
    let handle: CropEditorModel.Handle

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let length: CGFloat = 12
            var path = Path()
            switch handle {
            case .top, .bottom:
                path.move(to: CGPoint(x: c.x - length, y: c.y))
                path.addLine(to: CGPoint(x: c.x + length, y: c.y))
            case .left, .right:
                path.move(to: CGPoint(x: c.x, y: c.y - length))
                path.addLine(to: CGPoint(x: c.x, y: c.y + length))
            default:
                // The L opens towards the inside of the crop.
                let sx: CGFloat = [.topLeft, .bottomLeft].contains(handle) ? 1 : -1
                let sy: CGFloat = [.topLeft, .topRight].contains(handle) ? 1 : -1
                path.move(to: CGPoint(x: c.x + sx * length, y: c.y))
                path.addLine(to: c)
                path.addLine(to: CGPoint(x: c.x, y: c.y + sy * length))
            }
            context.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

private extension View {
    /// The resize pointer for a handle, from macOS 15.
    @ViewBuilder func resizeCursor(for handle: CropEditorModel.Handle) -> some View {
        if #available(macOS 15.0, *) {
            switch handle {
            case .topLeft: pointerStyle(.frameResize(position: .topLeading))
            case .top: pointerStyle(.frameResize(position: .top))
            case .topRight: pointerStyle(.frameResize(position: .topTrailing))
            case .right: pointerStyle(.frameResize(position: .trailing))
            case .bottomRight: pointerStyle(.frameResize(position: .bottomTrailing))
            case .bottom: pointerStyle(.frameResize(position: .bottom))
            case .bottomLeft: pointerStyle(.frameResize(position: .bottomLeading))
            case .left: pointerStyle(.frameResize(position: .leading))
            case .move: self
            }
        } else {
            self
        }
    }

    @ViewBuilder func moveCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.grabIdle)
        } else {
            self
        }
    }
}
