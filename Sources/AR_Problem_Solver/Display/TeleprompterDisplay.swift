import MWDATDisplay

/// Builds the glasses-display pages for the teleprompter flow. Each call returns
/// exactly one root `FlexBox` (the DAT contract: one root layout per send).
///
/// DAT 0.9 has no scrolling primitive, so "teleprompter" == one step per page,
/// advanced with the Neural Wristband via the `Previous` / `Next` buttons.
enum TeleprompterDisplay {

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
                Text(problem, style: .meta, color: .secondary)
                Text("Step \(step.number) of \(count)", style: .meta, color: .secondary)
                Text(step.text, style: .body)
            }
            .padding(24)
            .background(.card)

            FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
                ButtonGroup {
                    Button(
                        label: isFirst ? "Restart" : "Back",
                        style: .primary,
                        iconName: .triangleLeftVerticalLine,
                        onClick: onPrevious
                    )
                    Button(
                        label: isLast ? "Done" : "Next",
                        style: .primary,
                        iconName: isLast ? .checkmark : .triangleRightVerticalLine,
                        onClick: onNext
                    )
                    Button(label: "Repeat", style: .secondary, onClick: onRepeat)
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
