import AppKit
import CleanerCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let openStorage: () -> Void
    let open: (ModuleKind) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                hero
                if !model.hasFullDiskAccess {
                    AccessNotice()
                }
                TrashCard(model: model)
                moduleGrid
                if let lastScan = model.lastScan {
                    TimelineView(.everyMinute) { _ in
                        Text("Last scan: \(lastScan.formatted(.relative(presentation: .named)))")
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Hero

    /// Removable space first, then the disk it belongs to.
    private var hero: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(alignment: .top, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Removable space")
                        .font(.headline)
                        .foregroundStyle(.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    removableFigures
                }
                Spacer(minLength: Space.l)
                volumeSummary
            }
            if let volume = model.volume {
                StorageBar(volume: volume, removable: model.safeBytes, isStale: model.isScanning)
            }
            Button(action: openStorage) {
                Label("See what's using space", systemImage: "chart.pie")
            }
            .secondaryButtonStyle()
        }
        .padding(Space.xl)
        .surface()
    }

    @ViewBuilder private var removableFigures: some View {
        Group {
            if let removable = model.safeBytes, let review = model.reviewBytes {
                if removable > 0 || review == 0 {
                    FigureText(text: Text(removable.byteString), size: 44)
                }
                if removable == 0, review == 0 {
                    Text("Nothing significant to remove was found.").foregroundStyle(.textSecondary)
                }
                // Review items are the user's own decision, so they're never part of the total.
                if review > 0 {
                    Text("\(review.byteString) more to review")
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                }
            } else {
                FigureText(text: Text(verbatim: "—"), size: 44)
                    .foregroundStyle(.textSecondary)
                    .accessibilityLabel(Text("Not scanned"))
                Text("Scan to see how much space you can get back.")
                    .foregroundStyle(.textSecondary)
            }
        }
        .opacity(model.isScanning ? Motion.staleOpacity : 1)
        .animation(.snappy, value: model.safeBytes)
    }

    @ViewBuilder private var volumeSummary: some View {
        if let volume = model.volume {
            VStack(alignment: .trailing, spacing: Space.xxs) {
                Label {
                    Text(verbatim: volume.name)
                } icon: {
                    Image(systemName: "internaldrive").foregroundStyle(.textSecondary)
                }
                .font(.headline)
                Text("\(volume.usedBytes.byteString) of \(volume.totalBytes.byteString) used")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.textSecondary)
            }
        } else if model.volumeUnavailable {
            Text("Disk information is unavailable.").foregroundStyle(.textSecondary)
        }
    }

    // MARK: Modules

    private var moduleGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Metrics.moduleCardMinWidth), spacing: Space.l)],
            spacing: Space.l
        ) {
            ForEach(ModuleKind.allCases) { kind in
                ModuleCard(
                    kind: kind,
                    result: model.results[kind],
                    isScanning: model.scanning.contains(kind),
                    open: { open(kind) }
                )
            }
        }
    }
}

/// Neutral, not alarming: without Full Disk Access some folders can't be measured.
/// Walks through granting it, including the case where macOS forgot an earlier grant.
private struct AccessNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .center, spacing: Space.m) {
                IconTile(symbol: "lock.fill", tint: .gray, size: 32)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Give Ferah Full Disk Access to see everything")
                    Text("Without it, macOS hides some folders (like Mail and other apps' data), so sizes come out smaller than they are.")
                        .font(.callout)
                        .foregroundStyle(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("1. Open Full Disk Access in System Settings.")
                Text("2. Turn on Ferah. If it's missing, drag Ferah from Finder into the list. If it's already on, remove it with – and add it again.")
                Text("3. Reopen Ferah.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .prominentButtonStyle()
                Button("Show Ferah in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .secondaryButtonStyle()
                Button("Reopen Ferah", action: Self.relaunch)
                    .secondaryButtonStyle()
            }
        }
        .padding(Space.l)
        .surface()
        .accessibilityElement(children: .contain)
    }

    /// macOS applies the grant only to a newly started app.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
