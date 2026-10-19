import ConverterCore
import XCTest
@testable import ConverterApp

final class JobQueueTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder("Queue")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    func testConvertsBesideTheOriginalWithFinderStyleNames() async throws {
        let queue = JobQueue()
        let input = try makeImage("photo.png", in: folder)
        let jpeg = try XCTUnwrap(ConverterRegistry.standard.converter(id: "image.jpeg"))
        var finished = 0
        queue.onFinish = { _ in finished += 1 }

        let first = queue.enqueue(jpeg, on: [input])
        try await waitUntilIdle(queue)
        let second = queue.enqueue(jpeg, on: [input])
        try await waitUntilIdle(queue)

        XCTAssertEqual(first[0].state, .succeeded(folder.appendingPathComponent("photo.jpg")))
        XCTAssertEqual(second[0].state, .succeeded(folder.appendingPathComponent("photo 2.jpg")))
        XCTAssertEqual(first[0].progress, 1)
        XCTAssertEqual(finished, 2)
        XCTAssertEqual(queue.jobs.map(\.id), [second[0].id, first[0].id], "newest first")
        XCTAssertNil(queue.overallProgress)
    }

    @MainActor
    func testRunsAtMostTheConcurrencyLimit() async throws {
        let queue = JobQueue(maxConcurrent: 1)
        let gate = Gate()
        let inputs = try (1...3).map { try makeImage("p\($0).png", in: folder) }
        let jobs = queue.enqueue(GatedConverter(gate: gate), on: inputs)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(gate.startCount, 1, "only one job may run")
        XCTAssertEqual(jobs.map(\.state), [.running, .queued, .queued], "oldest runs first")
        XCTAssertNotNil(queue.overallProgress)

        gate.openGate()
        try await waitUntilIdle(queue)
        XCTAssertEqual(gate.startCount, 3)
        XCTAssertTrue(jobs.allSatisfy { if case .succeeded = $0.state { true } else { false } })
    }

    @MainActor
    func testCancellingRunningAndWaitingJobsLeavesNoFiles() async throws {
        let queue = JobQueue(maxConcurrent: 1)
        let gate = Gate()
        let inputs = try (1...2).map { try makeImage("p\($0).png", in: folder) }
        let jobs = queue.enqueue(GatedConverter(gate: gate), on: inputs)
        while gate.startCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }

        queue.cancel(jobs[1])
        XCTAssertEqual(jobs[1].state, .cancelled, "a waiting job cancels at once")
        queue.cancel(jobs[0])
        try await waitUntilIdle(queue)

        XCTAssertEqual(jobs.map(\.state), [.cancelled, .cancelled])
        XCTAssertEqual(gate.startCount, 1, "the cancelled waiting job never started")
        XCTAssertEqual(try folderContents(folder), ["p1.png", "p2.png"])
    }

    @MainActor
    func testFailureIsReported() async throws {
        let queue = JobQueue()
        let jobs = queue.enqueue(FailingConverter(), on: [try makeImage("p.png", in: folder)])
        try await waitUntilIdle(queue)
        XCTAssertEqual(jobs[0].state, .failed("Conversion failed: simulated"))
        XCTAssertEqual(try folderContents(folder), ["p.png"])
    }

    @MainActor
    func testClearFinishedKeepsActiveJobs() async throws {
        let queue = JobQueue(maxConcurrent: 1)
        let gate = Gate()
        let done = queue.enqueue(FailingConverter(), on: [try makeImage("a.png", in: folder)])
        try await waitUntilIdle(queue)
        let running = queue.enqueue(GatedConverter(gate: gate), on: [try makeImage("b.png", in: folder)])

        queue.clearFinished()
        XCTAssertEqual(queue.jobs.map(\.id), [running[0].id])
        XCTAssertFalse(queue.jobs.contains { $0.id == done[0].id })
        gate.openGate()
        try await waitUntilIdle(queue)
    }
}
