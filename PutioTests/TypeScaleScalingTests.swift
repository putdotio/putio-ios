import XCTest
@testable import Putio

// Pins the Dynamic Type contract of the design-system Type · Scale: every role
// is anchored to a scalable iOS text style, so brand type grows and shrinks
// with the system accessibility text-size setting instead of being frozen at a
// fixed point size. Runs on system fonts (verification builds bundle no brand
// faces), which is the fallback path — the scaling mechanism is identical for
// the brand faces, only the family differs.
@MainActor
final class TypeScaleScalingTests: XCTestCase {
    // Smallest to largest, spanning the standard and accessibility ranges.
    private let ramp: [UIContentSizeCategory] = [
        .extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge
    ]

    func testEveryRoleScalesWithContentSizeCategory() {
        XCTAssertEqual(TypeScaleSpecimen.rows.count, 10, "specimen must cover every design-system role")

        for row in TypeScaleSpecimen.rows {
            let sizes = ramp.map { TypeScaleSpecimen.font(for: row, category: $0).pointSize }

            // Non-decreasing across the ramp: a role frozen at a fixed size (or
            // anchored to a non-scaling context) would shrink somewhere. Large
            // titles plateau between the top accessibility steps, so this is
            // >=, not strictly-increasing at every adjacent step.
            for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    smaller, larger,
                    "\(row.role) must not shrink as the content size category grows (got \(sizes))"
                )
            }

            // But end to end it must genuinely grow — the whole point of anchoring
            // to a Dynamic Type style rather than a fixed point size.
            XCTAssertGreaterThan(
                sizes.last!, sizes.first!,
                "\(row.role) must be larger at the largest accessibility size than the smallest (got \(sizes))"
            )
        }
    }

    // End-to-end proof of the live wiring the branded labels rely on: a stack of
    // real specimen labels (branded when the faces are present) grows when the
    // surrounding trait environment's content size category increases, driven by
    // adjustsFontForContentSizeCategory — not by rebuilding the fonts.
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
