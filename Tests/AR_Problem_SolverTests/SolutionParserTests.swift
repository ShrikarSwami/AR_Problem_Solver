import XCTest
@testable import AR_Problem_Solver

final class SolutionParserTests: XCTestCase {
    func testParsesContractFormat() {
        let raw = """
        PROBLEM: Solve 2x + 4 = 10 for x.
        STEP 1: Subtract 4 from both sides to get 2x = 6.
        STEP 2: Divide both sides by 2.
        STEP 3: x = 3.
        DONE
        """
        let solution = SolutionParser.parse(raw)
        XCTAssertEqual(solution.problem, "Solve 2x + 4 = 10 for x.")
        XCTAssertEqual(solution.steps.map(\.number), [1, 2, 3])
        XCTAssertEqual(solution.steps.first?.text, "Subtract 4 from both sides to get 2x = 6.")
    }

    func testHandlesNumberedListFallback() {
        let raw = """
        Here is what to do:
        1. Unplug the device.
        2. Wait ten seconds.
        3. Plug it back in.
        """
        let solution = SolutionParser.parse(raw)
        XCTAssertEqual(solution.steps.count, 3)
        XCTAssertEqual(solution.steps[1].text, "Wait ten seconds.")
    }

    func testWholeTextBecomesOneStepWhenUnstructured() {
        let solution = SolutionParser.parse("Just tighten the bolt clockwise until snug.")
        XCTAssertEqual(solution.steps.count, 1)
        XCTAssertFalse(solution.isEmpty)
    }

    func testLongStepIsSoftSplit() {
        let sentence = String(repeating: "This is a fairly long clause that keeps going. ", count: 10)
        let raw = "PROBLEM: Long one.\nSTEP 1: \(sentence)\nDONE"
        let solution = SolutionParser.parse(raw)
        XCTAssertGreaterThan(solution.steps.count, 1)
        for step in solution.steps {
            XCTAssertLessThanOrEqual(step.text.count, SolutionParser.maxStepCharacters)
        }
        XCTAssertEqual(solution.steps.map(\.number), Array(1...solution.steps.count))
    }
}
