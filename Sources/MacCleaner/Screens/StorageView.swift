import AppKit
import CleanerCore
import SwiftUI

/// Where the disk's space goes: the home folder and applications, measured folder by folder.
/// Any folder opens to show what's inside, largest first.
struct StorageView: View {
    let model: AppModel

    /// Folders opened so far; empty means the top level.
    @ViewState private var path: [URL] = []
    @ViewState private var pendingTrash: StorageEntry?
    @ViewState private var outcome: TrashOutcome?

    var body: some View {
        Group {
            if let map = model.storageMap, !model.isAnalyzingStorage {
                content(map)
            } else if let progress = model.storageProgress {
                analyzing(progress)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Storage")
                    } icon: {
                        IconTile(symbol: "chart.pie.fill", tint: .indigo, size: 56)
                    }
                } description: {
                    Text("See which folders take up space on your Mac, and open any of them to look deeper.")
                } actions: {
                    Button("Analyze Storage", action: model.analyzeStorage)
                        .prominentButtonStyle()
                        .controlSize(.large)
                }
            }
        }
        .confirmationDialog(
            Text("Move “\(pendingTrash?.name ?? "")” to the Trash?"),
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { entry in
            Button("Move to Trash (\(entry.bytes.byteString))") { Task { await moveToTrash(entry) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can put it back from the Trash. The space is freed when you empty the Trash.")
        }
    }

    private func analyzing(_ progress: Int) -> some View {
        VStack(spacing: Space.l) {
            ProgressView()
            Text("Measuring folders…").font(.headline)
            Text("\(progress) files measured")
                .monospacedDigit()
                .foregroundStyle(.textSecondary)
                .contentTransition(.numericText())
            Button("Cancel", action: model.cancelStorageAnalysis)
                .secondaryButtonStyle()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Map

    private func content(_ map: StorageMap) -> some View {
        let current = path.last
        let entries = current.map { map.entries(in: $0) ?? [] } ?? topLevel(map)
        let total = current.flatMap { map.size(of: $0) } ?? entries.reduce(0) { $0 + $1.bytes }

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.l) {
                if current == nil {
                    StorageBreakdown(entries: entries, total: total)
                }
                if let outcome {
                    TrashResultBanner(outcome: outcome, model: model) { self.outcome = nil }
                }
                if !map.unreadable.isEmpty {
                    Group {
                        if model.hasFullDiskAccess {
                            Label("Some folders only macOS can read, so they're counted under macOS and other data.", systemImage: "lock")
                        } else {
                            Label("Some folders couldn't be read, so they're counted under macOS and other data. Grant Full Disk Access to measure them.",
                                  systemImage: "lock")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                }
                navigationBar(current: current, total: total)
            }
            .padding(Metrics.windowPadding)

            if entries.isEmpty {
                ContentUnavailableView {
                    Label("This folder is empty", systemImage: "folder")
                }
                .frame(maxHeight: .infinity)
            } else {
                entryList(entries, map: map, total: total)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    path = []
                    model.analyzeStorage()
                } label: {
                    Label("Analyze Again", systemImage: "arrow.clockwise")
                }
                .help(Text("Measure all folders again"))
            }
        }
    }

    private func entryList(_ entries: [StorageEntry], map: StorageMap, total: Int64) -> some View {
        ScrollView {
            LazyVStack(spacing: Space.xxs) {
                ForEach(entries) { entry in
                    StorageRow(entry: entry, share: total > 0 ? Double(entry.bytes) / Double(total) : 0,
                               home: model.home) {
                        if entry.isFolder, map.entries(in: entry.url) != nil { path.append(entry.url) }
                    } trash: {
                        pendingTrash = entry
                    }
                }
            }
            .padding(.horizontal, Metrics.windowPadding - Space.s)
            .padding(.bottom, Metrics.windowPadding)
        }
    }

    /// The top level: the home folder's contents and the application folders side by side,
    /// plus what the disk uses beyond them (macOS, system data, other users, snapshots).
    private func topLevel(_ map: StorageMap) -> [StorageEntry] {
        let home = map.roots[0]
        var entries = map.entries(in: home) ?? []
        for root in map.roots.dropFirst() {
            entries.append(StorageEntry(url: root, bytes: map.size(of: root) ?? 0, kind: .folder))
        }
        let measured = entries.reduce(0) { $0 + $1.bytes }
        if let used = model.volume?.usedBytes, used > measured {
            entries.append(StorageEntry(url: URL(fileURLWithPath: StorageRow.systemPath), bytes: used - measured, kind: .smallFiles(count: 0)))
        }
        return entries.sorted { $0.bytes > $1.bytes }
    }

    private func navigationBar(current: URL?, total: Int64) -> some View {
        HStack(spacing: Space.s) {
            Button {
                path.removeLast()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(path.isEmpty)
            .help(Text("Back"))
            .accessibilityLabel(Text("Back"))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    Button("Mac") { path = [] }
                        .buttonStyle(.plain)
                        .foregroundStyle(path.isEmpty ? Color.textPrimary : Color.accentColor)
                    ForEach(Array(path.enumerated()), id: \.element) { index, url in
                        Image(systemName: "chevron.forward")
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                        Button {
                            path = Array(path.prefix(index + 1))
                        } label: {
                            Text(verbatim: FileManager.default.displayName(atPath: url.path))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == path.count - 1 ? Color.textPrimary : Color.accentColor)
                    }
                }
                .font(.headline)
            }
            Spacer()
            Text(total.byteString)
                .font(.headline)
                .monospacedDigit()
            if let current {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([current])
                } label: {
                    Image(systemName: "folder")
                }
                .help(Text("Show in Finder"))
                .accessibilityLabel(Text("Show in Finder"))
            }
        }
        .secondaryButtonStyle()
        .controlSize(.small)
    }

    private func moveToTrash(_ entry: StorageEntry) async {
        let item = ScanItem(url: entry.url, bytes: entry.bytes, safety: .review)
        let outcome = await TrashService.moveToTrash([item], home: model.home, applicationRoots: model.applicationRoots)
        model.forget(outcome.moved)
        self.outcome = outcome
    }
}

/// The top level as one bar: the largest folders in color, the rest together, macOS and other data last.
private struct StorageBreakdown: View {
    let entries: [StorageEntry]
    let total: Int64

    private static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green]

    private var segments: [(name: Text, bytes: Int64, color: Color)] {
        let system = entries.first { $0.url.path == StorageRow.systemPath }
        let folders = entries.filter { $0.url.path != StorageRow.systemPath }
        var result = folders.prefix(Self.palette.count).enumerated().map { index, entry in
            (Text(verbatim: StorageRow.displayName(entry)), entry.bytes, Self.palette[index])
        }
        let rest = folders.dropFirst(Self.palette.count).reduce(0) { $0 + $1.bytes }
        if rest > 0 { result.append((Text("Other folders"), rest, Color.gray)) }
        if let system { result.append((Text("macOS and other data"), system.bytes, Color.barUsed)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            GeometryReader { proxy in
                HStack(spacing: Metrics.barGap) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: Metrics.barRadius)
                            .fill(segment.color.gradient)
                            .frame(width: max(2, proxy.size.width * Double(segment.bytes) / Double(max(total, 1))))
                    }
                }
            }
            .frame(height: Metrics.barHeight + 6)
            .accessibilityHidden(true)

            FlowLegend(items: segments.map { ($0.name, $0.bytes, $0.color) })
        }
        .padding(Space.l)
        .surface()
    }
}

private struct FlowLegend: View {
    let items: [(Text, Int64, Color)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: Space.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: Space.s) {
                    RoundedRectangle(cornerRadius: Metrics.swatchRadius)
                        .fill(item.2)
                        .frame(width: Metrics.swatchSize, height: Metrics.swatchSize)
                    item.0.lineLimit(1)
                    Text(item.1.byteString)
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// One folder or file with its size and its share of the folder it's in.
private struct StorageRow: View {
    let entry: StorageEntry
    let share: Double
    let home: URL
    let open: () -> Void
    let trash: () -> Void

    @ViewState private var isHovered = false

    /// Stands for everything outside the measured folders; never a real path.
    static let systemPath = "/.ferah-system"

    static func displayName(_ entry: StorageEntry) -> String {
        if entry.url.path == systemPath { return String(localized: "macOS and other data") }
        if case .smallFiles(let count) = entry.kind { return String(localized: "\(count) smaller files") }
        // Shared folders keep their full path, so /Library isn't mistaken for the home folder's Library.
        if AppModel.sharedStorageRoots.contains(where: { $0.path == entry.url.path }) { return entry.url.path }
        // "com.spotify.client" reads as "Spotify (com.spotify.client)" when that app is installed.
        return DisplayNames.name(for: entry.url)
    }

    private var isSystem: Bool { entry.url.path == Self.systemPath }
    private var isActionable: Bool { entry.kind == .folder || entry.kind == .file }

    var body: some View {
        HStack(spacing: Space.s) {
            // Only folders open; files keep full contrast so they don't read as unavailable.
            if entry.isFolder {
                Button(action: open) { rowContent }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
            } else {
                rowContent
            }
            actionsMenu
        }
        .padding(.horizontal, Space.s)
        .background(isHovered ? Color.rowHover : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        .onHover { isHovered = $0 }
        .contextMenu {
            if isActionable {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Divider()
                Button("Move to Trash…", action: trash)
            }
        }
        .help(isActionable ? entry.url.path : "")
    }

    private var rowContent: some View {
        HStack(spacing: Space.m) {
            icon
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(verbatim: Self.displayName(entry))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isSystem {
                    Text("macOS, system data, other users and snapshots. Ferah never touches these.")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                } else {
                    ShareBar(share: share)
                }
            }
            Spacer(minLength: Space.l)
            Text(entry.bytes.byteString)
                .monospacedDigit()
                .foregroundStyle(.textPrimary)
            Image(systemName: "chevron.forward")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.textSecondary)
                .opacity(entry.isFolder ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Space.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Visible way to act on a row, so moving to the Trash doesn't depend on finding the context menu.
    @ViewBuilder private var actionsMenu: some View {
        if isActionable {
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Divider()
                Button("Move to Trash…", action: trash)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Actions for \(Self.displayName(entry))"))
        } else {
            Image(systemName: "ellipsis.circle").hidden().accessibilityHidden(true)
        }
    }

    @ViewBuilder private var icon: some View {
        if isActionable {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: Metrics.itemIcon, height: Metrics.itemIcon)
                .accessibilityHidden(true)
        } else {
            IconTile(symbol: isSystem ? "apple.logo" : "doc.on.doc.fill", tint: .gray, size: Metrics.itemIcon)
        }
    }
}

private struct ShareBar: View {
    let share: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.barFree)
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: max(3, proxy.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(height: 5)
        .frame(maxWidth: 360)
        .accessibilityHidden(true)
    }
}
