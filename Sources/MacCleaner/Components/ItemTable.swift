import AppKit
import CleanerCore
import SwiftUI

/// Checkable list of found items. Nothing is checked unless the caller or the user checks it.
struct ItemTable: View {
    let items: [ScanItem]
    @Binding var checked: Set<URL>
    let home: URL

    @ViewState private var sortOrder = [KeyPathComparator(\ScanItem.bytes, order: .reverse)]

    var body: some View {
        // The table gets exactly the space it's offered: on its own it can ask for every row's height,
        // and a long list then pushes the whole window's content off screen.
        GeometryReader { proxy in
            table.frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minHeight: Metrics.tableMinHeight, maxHeight: .infinity)
    }

    private var table: some View {
        Table(items.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn(Text(verbatim: "")) { item in
                Toggle(isOn: binding(for: item)) { EmptyView() }
                    .labelsHidden()
                    .accessibilityLabel(Text(verbatim: DisplayNames.name(for: item.url)))
            }
            .width(24)

            TableColumn("Name", value: \ScanItem.name) { item in
                HStack(spacing: Space.s) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: Metrics.itemIcon, height: Metrics.itemIcon)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(verbatim: DisplayNames.name(for: item.url))
                            .foregroundStyle(.textPrimary)
                        Text(verbatim: DisplayNames.location(of: item.url, home: home))
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                            .truncationMode(.middle)
                        if let modified = item.modified {
                            Text("Modified \(modified.formatted(date: .abbreviated, time: .omitted))")
                                .font(.callout)
                                .foregroundStyle(.textSecondary)
                        }
                    }
                }
                .lineLimit(1)
                .padding(.vertical, Space.xs)
                .help(item.url.path)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
            }
            .width(min: 160, ideal: 260)

            TableColumn("Why", value: \ScanItem.safety.rawValue) { item in
                HStack(spacing: Space.s) {
                    SafetyLabelView(label: item.safety)
                    if TrashService.needsAdministrator(item.url) {
                        Image(systemName: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                            .help(Text("Moving this asks for an administrator password."))
                            .accessibilityLabel(Text("Moving this asks for an administrator password."))
                    }
                }
            }
            .width(min: 100, ideal: 120)

            TableColumn("Size", value: \ScanItem.bytes) { item in
                Text(item.bytes.byteString)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70)
        }
    }

    private func binding(for item: ScanItem) -> Binding<Bool> {
        Binding(
            get: { checked.contains(item.url) },
            set: { isOn in
                if isOn { checked.insert(item.url) } else { checked.remove(item.url) }
            }
        )
    }
}
