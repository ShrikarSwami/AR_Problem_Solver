import MWDATDisplay

/// Builds the glasses-display pages for the teleprompter flow. Each call returns
/// exactly one root `FlexBox` (the DAT contract: one root layout per send).
///
/// DAT 0.9 has no scrolling primitive, so "teleprompter" == one step per page,
/// advanced with the Neural Wristband via the `Back` / `Next` buttons.
enum TeleprompterDisplay {

    /// The glasses-side home screen. Sent on launch (and after each solve) so the
    /// wearer can start a scan from the display with a wristband tap — no need to
    /// touch the phone.
    static func home(onScan: @escaping @Sendable () -> Void) -> FlexBox {
        FlexBox(direction: .column, spacing: 12) {
            FlexBox(direction: .column, spacing: 4) {
                Text("AR Problem Solver", style: .heading)
                Text("Look at a problem, then tap Scan.", style: .body, color: .secondary)
            }
            .padding(24)
            .background(.card)

            FlexBox(direction: .row, alignment: .center, crossAlignment: .center) {
                ButtonGroup {
                    Button(label: "Scan", style: .primary, iconName: .fourCornerFrame, onClick: onScan)
                }
            }
        }
    }

    /// A single solution step.
    static func page(
        problem: String,
        step: SolutionStep,
        count: Int,
        onPrevious: @escaping @Sendable () -> Void,
        onNext: @escaping @Sendable () -> Void,
        onRepeat: @escaping @Sendable () -> Void
    ) -> FlexBox {
        let isFirst = step.number <= 1
        let isLast = step.number >= count

        return FlexBox(direction: .column, spacing: 12) {
            FlexBox(direction: .column, spacing: 4) {
                // The problem statement is only worth screen space on the first page.
                if isFirst {
                    Text(problem, style: .meta, color: .secondary)
                }
                Text("Step \(step.number) of \(count)", style: .meta, color: .secondary)
                Text(step.text, style: .body)
            }
            .padding(24)
            .background(.card)

            FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
                ButtonGroup {
                    if !isFirst {
                        Button(
                            label: "Back",
                            style: .secondary,
                            iconName: .triangleLeftVerticalLine,
                            onClick: onPrevious
                        )
                    }
                    Button(label: "Repeat", style: .secondary, iconName: .twoArrowsClockwise, onClick: onRepeat)
                    Button(
                        label: isLast ? "Done" : "Next",
                        style: .primary,
                        iconName: isLast ? .checkmark : .triangleRightVerticalLine,
                        onClick: onNext
                    )
                }
            }
        }
    }

    /// Shown while waiting on the model.
    static func thinking(problem: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text("Working on it…", style: .heading)
            Text(problem, style: .body, color: .secondary)
        }
        .padding(24)
        .background(.card)
    }

    /// Shown briefly after the wearer taps "Done" on the last step.
    static func completed() -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text("All steps done", style: .heading)
            Text("Take off the glasses or capture another problem.", style: .body, color: .secondary)
        }
        .padding(24)
        .background(.card)
    }

    /// Terminal error page.
    static func failure(_ message: String, onRetry: @escaping @Sendable () -> Void) -> FlexBox {
        FlexBox(direction: .column, spacing: 12) {
            FlexBox(direction: .column, spacing: 4) {
                Text("Couldn't solve this", style: .heading)
                Text(message, style: .body, color: .secondary)
            }
            .padding(24)
            .background(.card)

            FlexBox(direction: .row, alignment: .center, crossAlignment: .center) {
                ButtonGroup {
                    Button(label: "Try again", style: .primary, iconName: .checkmark, onClick: onRetry)
                }
            }
        }
    }
}
