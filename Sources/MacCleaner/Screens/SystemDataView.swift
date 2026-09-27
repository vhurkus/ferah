import AppKit
import CleanerCore
import SwiftUI

/// The parts of "System Data" the user can act on, each removed the way macOS expects:
/// snapshots with tmutil, simulators with simctl, backups to the Trash, Messages in Messages.
struct SystemDataView: View {
    let model: AppModel

    @ViewState private var pending: SystemDataItem?
    @ViewState private var working: String?
    @ViewState private var message: String?

    var body: some View {
        Group {
            if let items = model.systemData {
                list(items)
            } else {
                EmptyStateHero(
                    symbol: SystemDataView.symbol, tint: SystemDataView.tint, title: Text("System Data"),
                    message: Text("macOS counts these under System Data. Find out what they are and remove the ones you don't need."),
                    places: ["Time Machine snapshots", "Xcode simulators", "iPhone and iPad backups", "Messages attachments"],
                    actionTitle: model.isInspectingSystemData ? "Looking…" : "Look Inside",
                    isWorking: model.isInspectingSystemData, action: model.inspectSystemData
                )
            }
        }
        .confirmationDialog(
            Text(pending.map(confirmationTitle) ?? ""),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { item in
            Button(role: .destructive) { Task { await remove(item) } } label: { Text(actionTitle(item)) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(confirmationMessage(item))
        }
    }

    static let symbol = "square.stack.3d.up.fill"
    static let tint = Color.brown

    private func list(_ items: [SystemDataItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        let total = items.compactMap(\.bytes).reduce(0, +)
                        FigureText(text: Text(total.byteString), size: 34)
                        Text("Found in System Data. Everything else there belongs to macOS and is managed by it.")
                            .foregroundStyle(.textSecondary)
                    }
                    Spacer()
                    Button("Look Again", action: model.inspectSystemData)
                        .secondaryButtonStyle()
                        .disabled(model.isInspectingSystemData)
                }
                if let message {
                    Label(message, systemImage: "info.circle")
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surface()
                }
                if items.isEmpty {
                    Label("Nothing of this kind on this Mac.", systemImage: "checkmark.seal")
                        .foregroundStyle(.textSecondary)
                }
                ForEach(items) { item in
                    SystemDataCard(item: item, isWorking: working == item.id) {
                        if case .messagesAttachments = item.kind {
                            openMessages()
                        } else {
                            pending = item
                        }
                    }
                }
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func confirmationTitle(_ item: SystemDataItem) -> String {
        switch item.kind {
        case .localSnapshots: String(localized: "Delete Time Machine's local snapshots?")
        case .simulatorRuntime: String(localized: "Remove the \(item.title) simulator?")
        case .unavailableSimulators: String(localized: "Delete unavailable simulators?")
        case .deviceBackup: String(localized: "Move the backup of \(item.title) to the Trash?")
        case .messagesAttachments: ""
        }
    }

    private func confirmationMessage(_ item: SystemDataItem) -> String {
        switch item.kind {
        case .localSnapshots:
            String(localized: "Your Time Machine backups on the backup disk aren't affected. macOS asks for your password.")
        case .simulatorRuntime:
            String(localized: "Xcode downloads it again if a project needs it.")
        case .unavailableSimulators:
            String(localized: "These simulators can't run anymore because their runtime was removed.")
        case .deviceBackup:
            String(localized: "Keep it if it's your only backup of this device. You can put it back from the Trash.")
        case .messagesAttachments: ""
        }
    }

    private func actionTitle(_ item: SystemDataItem) -> String {
        switch item.kind {
        case .deviceBackup: String(localized: "Move to Trash")
        default: String(localized: "Delete")
        }
    }

    private func remove(_ item: SystemDataItem) async {
        working = item.id
        defer { working = nil }
        let inspector = model.systemDataInspector
        var error: String?
        switch item.kind {
        case .localSnapshots(let dates):
            error = await AdminRunner.run(SystemDataInspector.snapshotDeletion(dates),
                                          prompt: String(localized: "Ferah wants to delete Time Machine's local snapshots."))
        case .simulatorRuntime(let identifier):
            let result = await inspector.deleteRuntime(identifier)
            if !result.succeeded { error = result.error.isEmpty ? result.output : result.error }
        case .unavailableSimulators:
            let result = await inspector.deleteUnavailableSimulators()
            if !result.succeeded { error = result.error.isEmpty ? result.output : result.error }
        case .deviceBackup:
            guard let url = item.url else { return }
            let outcome = await TrashService.moveToTrash([ScanItem(url: url, bytes: item.bytes ?? 0, safety: .review)],
                                                         home: model.home, applicationRoots: model.applicationRoots)
            error = outcome.failures.first?.reason
        case .messagesAttachments:
            return
        }
        message = error.map { String(localized: "Couldn't remove \(item.title): \($0)") }
            ?? String(localized: "Removed \(item.title).")
        model.inspectSystemData()
    }

    private func openMessages() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

private struct SystemDataCard: View {
    let item: SystemDataItem
    let isWorking: Bool
    let act: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            IconTile(symbol: symbol, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(title).font(.headline)
                    if let detail = item.detail {
                        Text(verbatim: detail).foregroundStyle(.textSecondary)
                    }
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(2)
                if let lastUsed = item.lastUsed {
                    Text(lastUsedText(lastUsed))
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }
            Spacer(minLength: Space.l)
            Text(item.bytes.map(\.byteString) ?? String(localized: "Size not reported"))
                .monospacedDigit()
                .foregroundStyle(item.bytes == nil ? Color.textSecondary : Color.textPrimary)
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Button(buttonTitle, action: act)
                    .secondaryButtonStyle()
            }
            if let url = item.url, case .deviceBackup = item.kind {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help(Text("Show in Finder"))
                .accessibilityLabel(Text("Show in Finder"))
            }
        }
        .padding(Space.l)
        .surface()
    }

    private var title: String {
        switch item.kind {
        case .localSnapshots(let dates): String(localized: "Time Machine local snapshots (\(dates.count))")
        case .simulatorRuntime: String(localized: "\(item.title) simulator")
        case .unavailableSimulators(let count): String(localized: "\(count) unavailable simulators")
        case .deviceBackup: String(localized: "Backup of \(item.title)")
        case .messagesAttachments: String(localized: "Messages attachments")
        }
    }

    private var explanation: String {
        switch item.kind {
        case .localSnapshots:
            String(localized: "Hourly copies Time Machine keeps on this disk. macOS removes them when it needs space, but until then they count as System Data.")
        case .simulatorRuntime:
            String(localized: "Downloaded by Xcode to run apps in the simulator.")
        case .unavailableSimulators:
            String(localized: "Left behind by simulator runtimes that were removed.")
        case .deviceBackup:
            String(localized: "Made by Finder when backing up this device to the Mac.")
        case .messagesAttachments:
            String(localized: "Photos, videos and files from your conversations. Remove them in Messages: Settings › General › Keep messages, or delete large attachments in a conversation's details.")
        }
    }

    private var buttonTitle: String {
        switch item.kind {
        case .messagesAttachments: String(localized: "Open Messages")
        case .deviceBackup: String(localized: "Move to Trash…")
        default: String(localized: "Delete…")
        }
    }

    private func lastUsedText(_ date: Date) -> String {
        if case .deviceBackup = item.kind {
            return String(localized: "Backed up \(date.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Last used \(date.formatted(.relative(presentation: .named)))")
    }

    private var symbol: String {
        switch item.kind {
        case .localSnapshots: "clock.arrow.circlepath"
        case .simulatorRuntime, .unavailableSimulators: "iphone.gen3"
        case .deviceBackup: "externaldrive.fill.badge.timemachine"
        case .messagesAttachments: "message.fill"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .localSnapshots: .teal
        case .simulatorRuntime, .unavailableSimulators: .purple
        case .deviceBackup: .blue
        case .messagesAttachments: .green
        }
    }
}
