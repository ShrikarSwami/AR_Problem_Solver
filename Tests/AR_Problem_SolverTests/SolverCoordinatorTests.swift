import XCTest
import MWDATDisplay
@testable import AR_Problem_Solver

@MainActor
final class SolverCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        camera: PhotoCapturing,
        solver: ProblemSolving,
        display: DisplaySending
    ) -> SolverCoordinator {
        let coordinator = SolverCoordinator(camera: camera, solver: solver, display: display)
        coordinator.handoffDelay = .zero
        coordinator.completionLinger = .zero
        return coordinator
    }

    func testHappyPathReachesPresenting() async {
        let camera = FakeCamera(result: .success(Data([0xFF, 0xD8, 0xFF])))
        let solver = FakeSolver(result: .success("PROBLEM: Test.\nSTEP 1: Do a thing.\nSTEP 2: Do another.\nDONE"))
        let display = FakeDisplay()
        let coordinator = makeCoordinator(camera: camera, solver: solver, display: display)

        await coordinator.solve()

        guard case .presenting(let solution) = coordinator.state else {
            return XCTFail("expected .presenting, got \(coordinator.state)")
        }
        XCTAssertEqual(solution.steps.count, 2)
        XCTAssertGreaterThanOrEqual(display.sentPages.count, 1)
        XCTAssertNotNil(coordinator.teleprompter)
    }

    func testCaptureFailureSurfacesError() async {
        let camera = FakeCamera(result: .failure(GlassesError.notConnected))
        let solver = FakeSolver(result: .success("ignored"))
        let display = FakeDisplay()
        let coordinator = makeCoordinator(camera: camera, solver: solver, display: display)

        await coordinator.solve()

        guard case .failed(let message) = coordinator.state else {
            return XCTFail("expected .failed, got \(coordinator.state)")
        }
        XCTAssertEqual(message, GlassesError.notConnected.errorDescription)
    }

    func testUnauthorizedShortCircuits() async {
        let camera = FakeCamera(result: .success(Data([0x1])))
        let solver = FakeSolver(result: .success("PROBLEM: x\nSTEP 1: y\nDONE"))
        let display = FakeDisplay()
        let coordinator = SolverCoordinator(
            camera: camera, solver: solver, display: display,
            isDeviceReady: { false }
        )

        await coordinator.solve()

        guard case .failed(let message) = coordinator.state else {
            return XCTFail("expected .failed, got \(coordinator.state)")
        }
        XCTAssertEqual(message, GlassesError.notAuthorized.errorDescription)
        XCTAssertTrue(display.sentPages.isEmpty)
    }

    func testTeleprompterAdvancesAndFinishes() async {
        let camera = FakeCamera(result: .success(Data([0x1])))
        let solver = FakeSolver(result: .success("PROBLEM: T.\nSTEP 1: A.\nSTEP 2: B.\nDONE"))
        let display = FakeDisplay()
        let coordinator = makeCoordinator(camera: camera, solver: solver, display: display)
        await coordinator.solve()

        let teleprompter = try! XCTUnwrap(coordinator.teleprompter)
        XCTAssertEqual(teleprompter.index, 0)

        await teleprompter.next()
        XCTAssertEqual(teleprompter.index, 1)

        var idleFired = false
        coordinator.onIdle = { idleFired = true }

        await teleprompter.next() // past the end -> finish()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.teleprompter)
        XCTAssertTrue(display.ended)
        XCTAssertTrue(idleFired, "onIdle should fire so the app can re-send the glasses home screen")
    }
}

// MARK: - Fakes

@MainActor
private final class FakeCamera: PhotoCapturing {
    let result: Result<Data, Error>
    init(result: Result<Data, Error>) { self.result = result }
    func capturePhoto() async throws -> Data { try result.get() }
}

private struct FakeSolver: ProblemSolving {
    let result: Result<String, Error>
    func solve(imageJPEG: Data) async throws -> String { try result.get() }
}

@MainActor
private final class FakeDisplay: DisplaySending {
    private(set) var sentPages: [FlexBox] = []
    private(set) var ended = false
    var isConnected: Bool { true }
    func send(_ page: FlexBox) async throws { sentPages.append(page) }
    func end() { ended = true }
}
