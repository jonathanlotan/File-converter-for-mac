import ConverterCore
import Foundation
import os

/// One conversion: a file, or several files that make one output (a ZIP
/// of a selection).
@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued
        case running
        case succeeded(URL)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let inputs: [InputFile]
    let converter: any Converter
    @Published fileprivate(set) var state: State = .queued
    @Published fileprivate(set) var progress: Double = 0
    fileprivate var task: Task<Void, Never>?

    init(inputs: [InputFile], converter: any Converter) {
        self.inputs = inputs
        self.converter = converter
    }

    var title: String {
        let source = inputs.count == 1 ? inputs[0].url.lastPathComponent : "\(inputs.count) files"
        return "\(source) → \(converter.title)"
    }
    var isActive: Bool { state == .queued || state == .running }
    /// Video re-encodes use the media engine and lots of memory; they run
    /// one at a time even when other jobs run alongside.
    var isHeavy: Bool { converter.id.hasPrefix("video.") }
}

/// Runs conversions in the background, a few at a time, and keeps a short
/// history of finished jobs for the menu.
@MainActor
final class JobQueue: ObservableObject {
    /// Newest first.
    @Published private(set) var jobs: [Job] = []
    var options: ConversionOptions
    /// Called after jobs are added, finish, or are cleared.
    var onChange: (() -> Void)?
    /// Called when a job reaches a final state.
    var onFinish: ((Job) -> Void)?

    private let maxConcurrent: Int
    private let historyLimit = 20

    init(maxConcurrent: Int = 2, options: ConversionOptions = .default) {
        self.maxConcurrent = maxConcurrent
        self.options = options
    }

    var hasActiveJobs: Bool { jobs.contains { $0.isActive } }

    /// Mean progress of the jobs still running or waiting; nil when idle.
    var overallProgress: Double? {
        let active = jobs.filter(\.isActive)
        guard !active.isEmpty else { return nil }
        return active.map(\.progress).reduce(0, +) / Double(active.count)
    }

    @discardableResult
    func enqueue(_ converter: any Converter, on inputs: [InputFile]) -> [Job] {
        let added = converter.combinesInputs && inputs.count > 1
            ? [Job(inputs: inputs, converter: converter)]
            : inputs.map { Job(inputs: [$0], converter: converter) }
        jobs.insert(contentsOf: added.reversed(), at: 0)
        trimHistory()
        startWaitingJobs()
        onChange?()
        return added
    }

    func cancel(_ job: Job) {
        switch job.state {
        case .queued:
            job.state = .cancelled
            finished(job)
        case .running:
            job.task?.cancel()
        default:
            break
        }
    }

    func cancelAll() {
        jobs.filter(\.isActive).forEach(cancel)
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        onChange?()
    }

    // MARK: - Running

    private func startWaitingJobs() {
        let running = jobs.filter { $0.state == .running }
        var free = maxConcurrent - running.count
        var heavyRunning = running.contains(where: \.isHeavy)
        // Oldest first: `jobs` is newest first.
        for job in jobs.reversed() where free > 0 && job.state == .queued {
            if job.isHeavy && heavyRunning { continue }
            start(job)
            free -= 1
            heavyRunning = heavyRunning || job.isHeavy
        }
    }

    private func start(_ job: Job) {
        job.state = .running
        let converter = job.converter
        let inputs = job.inputs
        let options = options
        let throttle = ProgressThrottle()

        job.task = Task { [weak self] in
            let outcome: Job.State
            do {
                // JobRunner.run isn't actor-isolated, so the conversion runs
                // on the global executor, off the main thread.
                let report: ProgressHandler = { fraction in
                    guard throttle.shouldReport(fraction) else { return }
                    Task { @MainActor in
                        if job.state == .running { job.progress = max(job.progress, fraction) }
                    }
                }
                let url = inputs.count == 1
                    ? try await JobRunner.run(converter, on: inputs[0], options: options, progress: report)
                    : try await JobRunner.runCombined(converter, on: inputs, options: options, progress: report)
                outcome = .succeeded(url)
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            job.state = outcome
            if case .succeeded = outcome { job.progress = 1 }
            job.task = nil
            self?.finished(job)
        }
    }

    private func finished(_ job: Job) {
        onFinish?(job)
        startWaitingJobs()
        onChange?()
    }

    private func trimHistory() {
        let finished = jobs.filter { !$0.isActive }
        guard finished.count > historyLimit else { return }
        let drop = Set(finished.suffix(finished.count - historyLimit).map(\.id))
        jobs.removeAll { drop.contains($0.id) }
    }
}

/// Lets through at most one progress update per percent, so a fast
/// converter doesn't flood the main thread.
final class ProgressThrottle: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: -1.0)

    func shouldReport(_ fraction: Double) -> Bool {
        last.withLock { last in
            guard fraction >= 1 || fraction - last >= 0.01 else { return false }
            last = fraction
            return true
        }
    }
}
