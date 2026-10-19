import AppKit
import SwiftUI

/// One job in the menu bar menu: what's converting, its progress or result,
/// and Cancel / Show in Finder.
struct JobRowView: View {
    @ObservedObject var job: Job
    let onCancel: () -> Void
    let onReveal: (URL) -> Void

    static let width: CGFloat = 300
    static let height: CGFloat = 46

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.inputs[0].url.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            Spacer(minLength: 4)
            trailingButton
        }
        .padding(.horizontal, 14)
        .frame(width: Self.width, height: Self.height)
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .queued:
            Text("Waiting…").font(.caption).foregroundStyle(.secondary)
        case .running:
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
        case .succeeded(let url):
            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(1).help(message)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailingButton: some View {
        switch job.state {
        case .queued, .running:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel \(job.title)")
        case .succeeded(let url):
            Button { onReveal(url) } label: {
                Image(systemName: "magnifyingglass.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            .accessibilityLabel("Show \(url.lastPathComponent) in Finder")
        case .failed, .cancelled:
            EmptyView()
        }
    }
}
