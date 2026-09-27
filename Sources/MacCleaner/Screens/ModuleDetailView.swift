import AppKit
import CleanerCore
import SwiftUI

/// Caches & Logs, Developer Files, Large & Old Files: review the list, check items, move them to the Trash.
struct ModuleDetailView: View {
    let kind: ModuleKind
    let model: AppModel

    @ViewState private var checked: Set<URL> = []
    @ViewState private var isMoving = false
    @ViewState private var outcome: TrashOutcome?
    @ViewState private var filter = ""

    private var result: ModuleResult? { model.results[kind] }
    private var isScanning: Bool { model.scanning.contains(kind) }

    /// Items matching the search field by name or folder.
    private var visibleItems: [ScanItem] {
        guard let items = result?.items else { return [] }
        guard !filter.isEmpty else { return items }
        return items.filter {
            $0.url.path.localizedCaseInsensitiveContains(filter)
                || DisplayNames.name(for: $0.url).localizedCaseInsensitiveContains(filter)
        }
    }

    private var selectedItems: [ScanItem] { result?.items.filter { checked.contains($0.url) } ?? [] }

    /// Warnings for the confirmation: checked items the search hides, and items of apps that are still open.
    private var confirmationNotes: [Text] {
        var notes: [Text] = []
        let visible = Set(visibleItems.map(\.url))
        let hidden = selectedItems.filter { !visible.contains($0.url) }.count
        if hidden > 0 {
            notes.append(Text("Includes \(hidden) checked items hidden by the search."))
        }
        let openApps = OpenApps.names(owning: selectedItems)
        if !openApps.isEmpty {
            notes.append(Text("Some items belong to apps that are open: \(openApps.formatted(.list(type: .and))). Quit them first so they don't recreate the files right away."))
        }
        return notes
    }

    var body: some View {
        Group {
            if result == nil {
                // Before the first scan there's nothing to list: one screen that explains and starts it.
                EmptyStateHero(
                    symbol: kind.symbol, tint: kind.tint, title: Text(kind.title), message: Text(kind.explanation),
                    places: kind.places, labels: kind.expectedLabels,
                    actionTitle: isScanning ? "Scanning…" : "Start Scan", isWorking: isScanning
                ) {
                    model.scan([kind])
                }
                .disabled(model.isScanning && !isScanning)
            } else if let result, result.items.isEmpty, !isScanning {
                EmptyStateHero(
                    symbol: "checkmark.seal.fill", tint: .green, title: Text("All clean"),
                    message: Text("Nothing significant to remove was found."),
                    actionTitle: "Scan Again"
                ) {
                    model.scan([kind])
                }
                .disabled(model.isScanning)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(Metrics.windowPadding)
                    content
                }
                .modifier(SearchableWhen(isEnabled: !(result?.items.isEmpty ?? true), text: $filter))
            }
        }
        .onChange(of: result?.items.map(\.url)) { _, urls in
            // Keep only checks that still point at listed items.
            checked.formIntersection(Set(urls ?? []))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .center, spacing: Space.l) {
                IconTile(symbol: kind.symbol, tint: kind.tint, size: 52)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    if let result {
                        FigureText(text: Text(result.totalBytes.byteString), size: 30)
                            .opacity(isScanning ? Motion.staleOpacity : 1)
                            .animation(.snappy, value: result.totalBytes)
                    }
                    Text(kind.explanation)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isScanning {
                    ProgressView().controlSize(.small).accessibilityLabel(Text("Scanning"))
                } else if result != nil {
                    Button("Scan Again") { model.scan([kind]) }
                        .secondaryButtonStyle()
                        .disabled(model.isScanning)
                }
            }
            if let outcome {
                TrashResultBanner(outcome: outcome, model: model) { self.outcome = nil }
            }
            if let result, !result.items.isEmpty {
                HStack(spacing: Space.m) {
                    Button("Select Rebuilt & Safe") {
                        checked.formUnion(visibleItems.filter { $0.safety != .review }.map(\.url))
                    }
                    .disabled(visibleItems.allSatisfy { $0.safety == .review })
                    Button("Deselect All") { checked = [] }
                        .disabled(checked.isEmpty)
                    Spacer()
                    SafetyLabelSummary(kind: kind, result: result)
                }
                .secondaryButtonStyle()
                .controlSize(.small)
            }
        }
        .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if let result, !result.items.isEmpty {
            ItemTable(items: visibleItems, checked: $checked, home: model.home)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    TrashBar(selected: selectedItems, isWorking: isMoving, notes: confirmationNotes) {
                        Task { await moveChecked(from: result) }
                    }
                }
        } else if isScanning {
            ProgressView("Scanning")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func moveChecked(from result: ModuleResult) async {
        isMoving = true
        let items = result.items.filter { checked.contains($0.url) }
        let outcome = await TrashService.moveToTrash(items, home: model.home, applicationRoots: model.applicationRoots)
        model.forget(outcome.moved)
        checked.subtract(outcome.moved)
        self.outcome = outcome
        isMoving = false
    }
}

/// Running apps that own found items, matched by bundle identifier (cache folders are named after it).
@MainActor
enum OpenApps {
    static func names(owning items: [ScanItem]) -> [String] {
        let running = NSWorkspace.shared.runningApplications
        let names = items.compactMap { item -> String? in
            let name = item.name.lowercased()
            return running.first { app in
                guard let id = app.bundleIdentifier?.lowercased() else { return false }
                return name == id || name.hasPrefix(id + ".")
            }?.localizedName
        }
        return Array(Set(names)).sorted()
    }
}

/// Search only makes sense once there's a list to search.
private struct SearchableWhen: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, placement: .toolbar, prompt: Text("Search"))
        } else {
            content
        }
    }
}
