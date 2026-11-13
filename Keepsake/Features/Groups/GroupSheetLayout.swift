import Foundation

enum GroupSheetLayout {
    enum Pose: CaseIterable, Sendable {
        case collapsed, expanded, selector
    }

    static func height(
        in viewport: CGFloat,
        pose: Pose,
        accessibility: Bool = false,
        headerClearance: CGFloat = 96
    ) -> CGFloat {
        let available = max(0, viewport)
        let ceiling = available - min(max(0, headerClearance), available / 2)
        let referenceHeight: CGFloat = switch pose {
        case .collapsed: 328
        case .expanded: 548
        case .selector: 198
        }
        return min(ceiling, accessibility ? ceiling : available * referenceHeight / 720)
    }

    static func selectorWidth(in available: CGFloat, preferred: CGFloat, accessibility: Bool) -> CGFloat {
        max(0, min(preferred, available - (accessibility ? 0 : 152)))
    }
}
