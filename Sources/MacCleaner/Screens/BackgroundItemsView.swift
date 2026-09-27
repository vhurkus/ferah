import AppKit
import CleanerCore
import SwiftUI

/// What starts on its own: launch agents and daemons, whose they are, and a way to turn them off.
struct BackgroundItemsView: View {
    let model: AppModel

    static let symbol = "bolt.horizontal.circle.fill"
    static let tint = Color.pink

    @ViewState private var working: URL?
    @ViewState private var message: String?
    @ViewState private var pendingRemoval: BackgroundItem?

    var body: some View {
        Group {
            if let items = model.backgroundItems {
                list(items)
            } else {
                EmptyStateHero(
                    symbol: Self.symbol, tint: Self.tint, title: Text("Background Items"),
                    message: Text("Programs apps set up to start on their own, at login or when the Mac starts. See whose they are and turn off the ones you don't need."),
                    places: ["~/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"],
                    actionTitle: model.isLoadingBackgroundItems ? "Looking…" : "Show Background Items",
                    isWorking: model.isLoadingBackgroundItems, action: model.loadBackgroundItems
                )
            }
        }
        .confirmationDialog(
            Text("Remove “\(pendingRemoval?.label ?? "")”?"),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { item in
            Button("Move to Trash", role: .destructive) { Task { await remove(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.ownerName == nil || item.isBroken
                 ? "It's stopped and its file goes to the Trash."
                 : "Its app may stop working properly or set it up again. Turning it off is usually enough.")
        }
    }

    private func list(_ items: [BackgroundItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .top, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("\(items.count) background items")
                            .font(.system(.title, design: .rounded, weight: .bold))
                        Text("Apps can also add login items that only System Settings shows.")
                            .foregroundStyle(.textSecondary)
                    }
                    Spacer()
                    Button("Login Items Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .secondaryButtonStyle()
                    Button("Look Again", action: model.loadBackgroundItems)
                        .secondaryButtonStyle()
                        .disabled(model.isLoadingBackgroundItems)
                }
                if let message {
                    Label(message, systemImage: "info.circle")
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surface()
                }
                if items.isEmpty {
                    Label("No apps start anything on their own.", systemImage: "checkmark.seal")
                        .foregroundStyle(.textSecondary)
                }
                // Broken ones first: they're the ones worth removing.
                ForEach(items.sorted { ($0.isBroken ? 0 : 1, $0.ownerName ?? "~", $0.label) < ($1.isBroken ? 0 : 1, $1.ownerName ?? "~", $1.label) }) { item in
                    BackgroundItemRow(item: item, isWorking: working == item.plist) { enabled in
                        Task { await setEnabled(item, enabled) }
                    } remove: {
                        pendingRemoval = item
                    }
                }
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func setEnabled(_ item: BackgroundItem, _ enabled: Bool) async {
        working = item.plist
        defer { working = nil }
        let commands = enabled ? BackgroundItemFinder.enableCommands(for: item) : BackgroundItemFinder.disableCommands(for: item)
        var error: String?
        if BackgroundItemFinder.needsAdministrator(item) {
            error = await AdminRunner.run(commands, prompt: String(localized: "Ferah wants to change a background item."))
        } else {
            var last = CommandResult(status: 0, output: "", error: "")
            for command in commands { last = await ProcessRunner().run(command[0], Array(command.dropFirst())) }
            if !last.succeeded { error = last.error.isEmpty ? last.output : last.error }
        }
        message = error.map { String(localized: "Couldn't change \(item.label): \($0)") }
            ?? (enabled ? String(localized: "\(item.label) is on.") : String(localized: "\(item.label) is off. It won't start again until you turn it on."))
        model.loadBackgroundItems()
    }

    private func remove(_ item: BackgroundItem) async {
        working = item.plist
        defer { working = nil }
        if BackgroundItemFinder.needsAdministrator(item) {
            // Stop it first: a daemon keeps running after its file is gone.
            _ = await AdminRunner.run(BackgroundItemFinder.disableCommands(for: item),
                                      prompt: String(localized: "Ferah wants to change a background item."))
        }
        let outcome = await TrashService.moveToTrash([ScanItem(url: item.plist, bytes: 0, safety: .review)],
                                                     home: model.home, applicationRoots: model.applicationRoots)
        message = outcome.failures.first.map { String(localized: "Couldn't remove \(item.label): \($0.reason)") }
            ?? String(localized: "Moved \(item.label) to the Trash.")
        model.loadBackgroundItems()
    }
}

private struct BackgroundItemRow: View {
    let item: BackgroundItem
    let isWorking: Bool
    let setEnabled: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            ownerIcon
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    Text(verbatim: item.ownerName ?? String(localized: "Unknown app")).font(.headline)
                    if item.isBroken {
                        Label("Program missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.reviewIcon)
                    }
                }
                Text(verbatim: item.label)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .textSelection(.enabled)
                HStack(spacing: Space.m) {
                    Label(scopeText, systemImage: item.scope == .system ? "lock" : "person")
                    if item.runsAtLoad { Label(item.scope == .system ? "Starts with the Mac" : "Starts at login", systemImage: "power") }
                    if item.keepsAlive { Label("Kept running", systemImage: "arrow.triangle.2.circlepath") }
                }
                .font(.caption)
                .foregroundStyle(.textSecondary)
            }
            Spacer(minLength: Space.l)
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Toggle(isOn: Binding(get: { !item.isDisabled }, set: { setEnabled($0) })) { EmptyView() }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(Text("\(item.ownerName ?? item.label) runs"))
                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.plist]) }
                    Divider()
                    Button("Move to Trash…", action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Actions for \(item.label)"))
            }
        }
        .padding(Space.l)
        .surface()
        .opacity(item.isDisabled ? 0.7 : 1)
    }

    private var scopeText: LocalizedStringKey {
        switch item.scope {
        case .user: "This user"
        case .allUsers: "All users"
        case .system: "System, needs your password"
        }
    }

    @ViewBuilder private var ownerIcon: some View {
        if let url = item.ownerURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
        } else {
            IconTile(symbol: item.isBroken ? "questionmark" : "gearshape.fill", tint: .gray, size: 40)
        }
    }
}
