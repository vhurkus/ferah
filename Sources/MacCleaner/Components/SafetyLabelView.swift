import CleanerCore
import SwiftUI

/// The signature element: why an item may be removed, as icon + text (never color alone).
struct SafetyLabelView: View {
    let label: SafetyLabel
    /// Shown after the title when a module mixes labels, e.g. "Review first (2)".
    var count: Int?

    var body: some View {
        Label {
            Group {
                if let count {
                    Text("\(Text(label.title)) (\(count))")
                } else {
                    Text(label.title)
                }
            }
            .foregroundStyle(.textSecondary)
        } icon: {
            Image(systemName: label.symbol).foregroundStyle(label.iconColor)
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
    }
}

/// Every label a module actually contains, so mixed modules are described honestly.
struct SafetyLabelSummary: View {
    let kind: ModuleKind
    let result: ModuleResult?
    var axis: Axis = .horizontal

    var body: some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: Space.m))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
        layout {
            if let result, !result.items.isEmpty {
                let labels = result.labels
                ForEach(labels, id: \.self) { label in
                    // Counts only matter where the user has to look: mixed modules with review items.
                    SafetyLabelView(label: label, count: labels.count > 1 && label == .review ? result.count(of: label) : nil)
                }
            } else {
                ForEach(kind.expectedLabels, id: \.self) { SafetyLabelView(label: $0) }
            }
        }
    }
}
