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

    func testShortCodeLinesPassThroughVerbatim() {
        let raw = """
        PROBLEM: Reverse a string in Python.
        STEP 1: Define a function that returns the reversed text.
        STEP 2: def reverse(s):
        STEP 3: loop: return s[::-1]
        STEP 4: Call reverse("abc") to check it prints "cba".
        DONE
        """
        let solution = SolutionParser.parse(raw)
        XCTAssertEqual(solution.steps.map(\.text), [
            "Define a function that returns the reversed text.",
            "def reverse(s):",
            "loop: return s[::-1]",
            "Call reverse(\"abc\") to check it prints \"cba\".",
        ])
    }

    func testTerseWordProblemFragmentsAreKept() {
        let raw = """
        PROBLEM: Train travels 60 miles in 1.5 hours. Find speed.
        STEP 1: distance 60 mi
        STEP 2: time 1.5 h
        STEP 3: 60 / 1.5
        STEP 4: 40 mph
        DONE
        """
        let solution = SolutionParser.parse(raw)
        XCTAssertEqual(solution.steps.count, 4)
        XCTAssertEqual(solution.steps.last?.text, "40 mph")
        XCTAssertEqual(solution.steps[2].text, "60 / 1.5")
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

    func testDecimalsAreNotSplitAcrossPages() {
        let long = "First measure the resistance carefully with a calibrated meter and note the reading. "
            + "The circuit should read exactly 3.14 ohms when the probes are seated firmly on the terminals "
            + "and the leads are not touching anything else in the enclosure at all right now."
        let raw = "PROBLEM: Check the resistor.\nSTEP 1: \(long)\nDONE"
        let solution = SolutionParser.parse(raw)
        XCTAssertGreaterThan(solution.steps.count, 1)
        XCTAssertFalse(solution.steps.contains { $0.text.hasSuffix("3.") || $0.text.hasPrefix("14 ") })
        XCTAssertTrue(solution.steps.contains { $0.text.contains("3.14 ohms") })
    }

    func testDashAndParenSeparators() {
        let raw = """
        PROBLEM: Reset the router.
        STEP 1 - Unplug the power cable.
        2) Wait thirty seconds.
        STEP 3: Plug it back in and wait for the lights.
        DONE
        """
        let solution = SolutionParser.parse(raw)
        XCTAssertEqual(solution.steps.map(\.text), [
            "Unplug the power cable.",
            "Wait thirty seconds.",
            "Plug it back in and wait for the lights.",
        ])
    }

    func testTrailingSignOffIsDropped() {
        let raw = """
        PROBLEM: Tighten the bolt.
        STEP 1: Turn the bolt clockwise until it is snug.
        DONE
        Good luck, you've got this!
        """
        let solution = SolutionParser.parse(raw)
        XCTAssertEqual(solution.steps.count, 1)
        XCTAssertEqual(solution.steps[0].text, "Turn the bolt clockwise until it is snug.")
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
