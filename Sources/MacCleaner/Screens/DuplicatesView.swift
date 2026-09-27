import AppKit
import CleanerCore
import SwiftUI

/// Identical files in the home folder, grouped. One copy of each always stays.
struct DuplicatesView: View {
    let model: AppModel

    static let symbol = "square.on.square.fill"
    static let tint = Color.cyan

    @ViewState private var checked: Set<URL> = []
    @ViewState private var isMoving = false
    @ViewState private var outcome: TrashOutcome?

    var body: some View {
        Group {
            if let groups = model.duplicates, model.duplicateProgress == nil {
                if groups.isEmpty {
                    EmptyStateHero(symbol: "checkmark.seal.fill", tint: .green, title: Text("No duplicates"),
                                   message: Text("No two files over 1 MB in your home folders have the same contents."),
                                   actionTitle: "Search Again", action: model.findDuplicates)
                } else {
                    list(groups)
                }
            } else if let progress = model.duplicateProgress {
                VStack(spacing: Space.l) {
                    ProgressView()
                    Text("Comparing files…").font(.headline)
                    Text("\(progress) files looked at")
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                        .contentTransition(.numericText())
                    Button("Cancel", action: model.cancelDuplicateSearch)
                        .secondaryButtonStyle()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateHero(
                    symbol: Self.symbol, tint: Self.tint, title: Text("Duplicates"),
                    message: Text("Find files that are exact copies of each other, compared byte for byte, and keep just one."),
                    places: ["Every folder in your home", "Files over 1 MB", "Identical contents only"],
                    actionTitle: "Find Duplicates", action: model.findDuplicates
                )
            }
        }
        .onChange(of: model.duplicates?.flatMap { $0.copies.map(\.url) }) { _, urls in
            checked.formIntersection(Set(urls ?? []))
        }
    }

    private func list(_ groups: [DuplicateGroup]) -> some View {
        let items = groups.flatMap { group in
            group.copies.map { ScanItem(url: $0.url, bytes: group.bytes, safety: .review, modified: $0.modified) }
        }
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        FigureText(text: Text(groups.reduce(0) { $0 + $1.wastedBytes }.byteString), size: 34)
                        Text("in \(groups.count) sets of identical files. One copy of each always stays.")
                            .foregroundStyle(.textSecondary)
                    }
                    Spacer()
                    Button("Select All but the Oldest") { checked = DuplicateFinder.allButOldest(groups) }
                    Button("Deselect All") { checked = [] }
                        .disabled(checked.isEmpty)
                    Button("Search Again", action: model.findDuplicates)
                }
                .secondaryButtonStyle()
                if let outcome {
                    TrashResultBanner(outcome: outcome, model: model) { self.outcome = nil }
                }
            }
            .padding(Metrics.windowPadding)

            ScrollView {
                LazyVStack(spacing: Space.m) {
                    ForEach(groups) { group in
                        DuplicateGroupCard(group: group, checked: $checked, home: model.home)
                    }
                }
                .padding(.horizontal, Metrics.windowPadding)
                .padding(.bottom, Metrics.windowPadding)
                .frame(maxWidth: Metrics.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TrashBar(selected: items.filter { checked.contains($0.url) }, isWorking: isMoving) {
                    Task { await moveChecked(items) }
                }
            }
        }
    }

    private func moveChecked(_ items: [ScanItem]) async {
        isMoving = true
        let selected = items.filter { checked.contains($0.url) }
        let outcome = await TrashService.moveToTrash(selected, home: model.home, applicationRoots: model.applicationRoots)
        model.forget(outcome.moved)
        checked.subtract(outcome.moved)
        self.outcome = outcome
        isMoving = false
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    @Binding var checked: Set<URL>
    let home: URL

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.copies[0].url.path))
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(verbatim: group.copies[0].url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(group.copies.count) copies of \(group.bytes.byteString)")
                        .font(.callout)
                        .foregroundStyle(.textSecondary)
                }
                Spacer()
                Text(group.wastedBytes.byteString)
                    .monospacedDigit()
                    .accessibilityLabel(Text("\(group.wastedBytes.byteString) can be freed"))
            }
            ForEach(Array(group.copies.enumerated()), id: \.element.id) { index, copy in
                let isChecked = checked.contains(copy.url)
                // The last unchecked copy can't be checked: one always stays.
                let isLastKept = !isChecked && group.copies.filter { !checked.contains($0.url) }.count == 1
                HStack(spacing: Space.s) {
                    Toggle(isOn: Binding(
                        get: { isChecked },
                        set: { if $0 { checked.insert(copy.url) } else { checked.remove(copy.url) } }
                    )) { EmptyView() }
                    .labelsHidden()
                    .disabled(isLastKept)
                    .help(isLastKept ? Text("One copy always stays.") : Text(""))
                    .accessibilityLabel(Text(verbatim: copy.url.path))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: DisplayNames.location(of: copy.url, home: home) + "/" + copy.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: Space.s) {
                            if let modified = copy.modified {
                                Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
                            }
                            if index == 0 { Text("Oldest") .fontWeight(.semibold) }
                            if isLastKept { Text("Kept").fontWeight(.semibold).foregroundStyle(.safeIcon) }
                        }
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([copy.url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Show in Finder"))
                    .accessibilityLabel(Text("Show in Finder"))
                }
                .padding(.leading, Space.xs)
            }
        }
        .padding(Space.l)
        .surface()
    }
}
