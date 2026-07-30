import XCTest
@testable import Putio

// Pins the Dynamic Type contract: every role is anchored to a scalable iOS text
// style rather than frozen at a fixed point size. The scaling mechanism is the
// same for brand and system faces, so asserting either proves the wiring.
@MainActor
final class TypeScaleScalingTests: XCTestCase {
    // Smallest to largest, across the standard and accessibility ranges.
    private let ramp: [UIContentSizeCategory] = [
        .extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge
    ]

    func testEveryRoleScalesWithContentSizeCategory() {
        XCTAssertEqual(TypeScaleSpecimen.rows.count, 10, "specimen must cover every design-system role")

        for row in TypeScaleSpecimen.rows {
            let sizes = ramp.map { TypeScaleSpecimen.font(for: row, category: $0).pointSize }

            // >= rather than strictly increasing: large titles plateau between
            // the top accessibility steps. A role frozen at a fixed size, or
            // anchored to a non-scaling context, would shrink somewhere.
            for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    smaller, larger,
                    "\(row.role) must not shrink as the content size category grows (got \(sizes))"
                )
            }

            // End to end it must still genuinely grow.
            XCTAssertGreaterThan(
                sizes.last!, sizes.first!,
                "\(row.role) must be larger at the largest accessibility size than the smallest (got \(sizes))"
            )
        }
    }

    // End-to-end: real labels grow with the surrounding trait environment via
    // adjustsFontForContentSizeCategory, without the fonts being rebuilt.
    func testBrandedSpecimenStackGrowsWithContentSizeCategory() {
        let stack = UIStackView(arrangedSubviews: TypeScaleSpecimen.rows.map { TypeScaleSpecimen.label(for: $0) })
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        func height(at category: UIContentSizeCategory) -> CGFloat {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 640))
            window.traitOverrides.preferredContentSizeCategory = category
            stack.removeFromSuperview()
            window.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                stack.widthAnchor.constraint(equalToConstant: 360),
                stack.topAnchor.constraint(equalTo: window.topAnchor)
            ])
            window.layoutIfNeeded()
            return stack.systemLayoutSizeFitting(
                CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }

        XCTAssertGreaterThan(
            height(at: .accessibilityExtraExtraExtraLarge), height(at: .large),
            "branded specimen labels must grow with the content size category"
        )
    }
}
