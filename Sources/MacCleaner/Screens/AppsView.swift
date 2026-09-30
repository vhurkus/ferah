import AppKit
import CleanerCore
import SwiftUI
import UniformTypeIdentifiers

/// App uninstaller: pick an app (or drop one on the window), review it and its leftovers, move them to the Trash.
struct AppsView: View {
    let model: AppModel

    @ViewState private var selectedURL: URL?
    @ViewState private var filter = ""
    @ViewState private var outcome: TrashOutcome?
    @ViewState private var isDropTargeted = false
    @ViewState private var dropRejection: TrashPolicy.Rejection?
    @ViewState private var sort = AppSort.size
    @ViewState private var showsOrphans = false
    @ViewState private var selectedTrashed: URL?
    @ViewState private var showsUpdatesOnly = false
    @ViewState private var isConfirmingUpdateCheck = false
    @AppStorage("hasExplainedUpdateCheck") private var hasExplainedUpdateCheck = false

    enum AppSort: String, CaseIterable, Identifiable {
        case name, size, lastUsed
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .name: "Name"
            case .size: "Size"
            case .lastUsed: "Last Used"
            }
        }
    }

    /// An installed app with what the scan measured about it.
    struct AppEntry: Identifiable {
        let app: InstalledApp
        let bytes: Int64
        let lastUsed: Date?
        var update: AppUpdate?
        var id: URL { app.url }
    }

    private var apps: [AppEntry] {
        let entries = (model.results[.apps]?.items ?? [])
            .map { AppEntry(app: InstalledApp(url: $0.url), bytes: $0.bytes, lastUsed: $0.lastUsed, update: model.appUpdates?[$0.url]) }
            .filter { filter.isEmpty || $0.app.name.localizedCaseInsensitiveContains(filter) }
            .filter { !showsUpdatesOnly || model.appUpdates?[$0.app.url] != nil }
        return entries.sorted { a, b in
            switch sort {
            case .name: a.app.name.localizedStandardCompare(b.app.name) == .orderedAscending
            case .size: a.bytes > b.bytes
            // Least recently used first: those are the candidates for removal. Never opened counts as oldest.
            case .lastUsed: (a.lastUsed ?? .distantPast) < (b.lastUsed ?? .distantPast)
            }
        }
    }

    var body: some View {
        Group {
            if model.results[.apps] == nil, model.trashedApps.isEmpty {
                // Keep the result of the last move visible even when the list is gone.
                VStack(spacing: 0) {
                    if let outcome {
                        TrashResultBanner(outcome: outcome, model: model) { self.outcome = nil }
                            .padding([.horizontal, .top], Metrics.windowPadding)
                    }
                    startHero
                }
            } else {
                HStack(spacing: 0) {
                    appList
                    Divider()
                    detail
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            // Only apps that could actually be removed; otherwise their Library data would be offered alone.
            if let rejection = TrashPolicy.check(url, home: model.home, applicationRoots: model.applicationRoots) {
                dropRejection = rejection
                return false
            }
            dropRejection = nil
            showsOrphans = false
            selectedTrashed = nil
            selectedURL = url
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onChange(of: model.requestedTrashedApp, initial: true) { _, url in
            guard let url else { return }
            selectedTrashed = url
            selectedURL = nil
            showsOrphans = false
            model.requestedTrashedApp = nil
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Metrics.groupRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(Space.xs)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var updatesControl: some View {
        HStack(spacing: Space.s) {
            if model.isCheckingUpdates {
                ProgressView().controlSize(.small)
                if let progress = model.updateProgress, progress.total > 0 {
                    Text("Checked \(progress.done) of \(progress.total) apps")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                } else {
                    Text("Checking for updates…").font(.caption).foregroundStyle(.textSecondary)
                }
            } else if let updates = model.appUpdates {
                Toggle(isOn: $showsUpdatesOnly) {
                    Text(updates.isEmpty ? "All apps are up to date" : "Updates only (\(updates.count))")
                }
                .toggleStyle(.checkbox)
                .disabled(updates.isEmpty)
                .font(.caption)
                Spacer()
                Button {
                    model.checkForAppUpdates()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(Text("Check Again"))
                .accessibilityLabel(Text("Check Again"))
            } else {
                Button {
                    if hasExplainedUpdateCheck { model.checkForAppUpdates() } else { isConfirmingUpdateCheck = true }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .secondaryButtonStyle()
                .controlSize(.small)
            }
        }
        .confirmationDialog(Text("Check your apps for updates?"), isPresented: $isConfirmingUpdateCheck) {
            Button("Check for Updates") {
                hasExplainedUpdateCheck = true
                model.checkForAppUpdates()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ferah asks the App Store, Homebrew's public catalog and each app's own update server for the newest version. That tells them which apps you have. Nothing is installed without you.")
        }
    }

    private var startHero: some View {
        EmptyStateHero(
            symbol: ModuleKind.apps.symbol, tint: ModuleKind.apps.tint, title: Text(ModuleKind.apps.title),
            message: Text("Remove apps together with the files they leave in your Library, and clean up after apps you've already deleted."),
            places: ModuleKind.apps.places,
            actionTitle: model.scanning.contains(.apps) ? "Scanning…" : "Start Scan",
            isWorking: model.scanning.contains(.apps)
        ) {
            model.scan([.apps])
        }
        .disabled(model.isScanning && !model.scanning.contains(.apps))
    }

    private var appList: some View {
        VStack(spacing: 0) {
            VStack(spacing: Space.s) {
                TextField("Search Apps", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Picker("Sort by", selection: $sort) {
                    ForEach(AppSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                updatesControl
            }
            .padding(Space.m)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filter.isEmpty, !showsUpdatesOnly, !model.trashedApps.isEmpty {
                        ForEach(model.trashedApps) { trashed in
                            TrashedAppRow(trashed: trashed, isSelected: selectedTrashed == trashed.app.url) {
                                selectedTrashed = trashed.app.url
                                showsOrphans = false
                                selectedURL = nil
                                dropRejection = nil
                            }
                        }
                        if model.orphans?.items.isEmpty ?? true { Divider().padding(.vertical, Space.xs) }
                    }
                    if let orphans = model.orphans, !orphans.items.isEmpty, filter.isEmpty, !showsUpdatesOnly {
                        OrphansRow(result: orphans, isSelected: showsOrphans) {
                            showsOrphans = true
                            selectedURL = nil
                            selectedTrashed = nil
                            dropRejection = nil
                        }
                        Divider().padding(.vertical, Space.xs)
                    }
                    let entries = apps
                    let names = Dictionary(grouping: entries, by: \.app.name)
                    ForEach(entries) { entry in
                        AppRow(entry: entry, isSelected: entry.app.url == selectedURL,
                               showsLocation: (names[entry.app.name]?.count ?? 0) > 1) {
                            selectedURL = entry.app.url
                            showsOrphans = false
                            selectedTrashed = nil
                            dropRejection = nil
                        }
                    }
                }
                .padding(.horizontal, Space.s)
            }
        }
        .frame(width: Metrics.appListWidth)
        .background(.bgContent)
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if let outcome {
                TrashResultBanner(outcome: outcome, model: model) { self.outcome = nil }
                    .padding([.horizontal, .top], Metrics.windowPadding)
            }
            if let dropRejection {
                DropRejectionNotice(rejection: dropRejection) { self.dropRejection = nil }
                    .padding([.horizontal, .top], Metrics.windowPadding)
            }
            if let selectedTrashed, let trashed = model.trashedApps.first(where: { $0.app.url == selectedTrashed }) {
                LeftoversView(
                    icon: Image(nsImage: NSWorkspace.shared.icon(forFile: trashed.app.url.path)),
                    title: Text("\(trashed.app.name) is in the Trash"),
                    message: Text("It left these files behind. The ones that are clearly its own are already checked."),
                    result: trashed.leftovers,
                    preselected: Set(trashed.leftovers.items.filter { $0.safety != .review }.map(\.url)),
                    model: model
                ) { self.outcome = $0 }
                .id(selectedTrashed)
            } else if showsOrphans, let orphans = model.orphans {
                LeftoversView(
                    icon: nil,
                    title: Text("Leftovers of removed apps"),
                    message: Text("These are named after apps that aren't on this Mac anymore. Check each one before moving it to the Trash."),
                    result: orphans, preselected: [], model: model
                ) { self.outcome = $0 }
            } else if let selectedURL {
                AppUninstallView(app: InstalledApp(url: selectedURL), model: model) { outcome in
                    self.outcome = outcome
                    if outcome.moved.contains(selectedURL) { self.selectedURL = nil }
                }
                .id(selectedURL)
            } else {
                ContentUnavailableView {
                    Label("Choose an app", systemImage: ModuleKind.apps.symbol)
                } description: {
                    Text("Pick an app from the list, or drag one here from Finder.")
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The entry for leftovers of apps that are gone, above the app list.
private struct OrphansRow: View {
    let result: ModuleResult
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Space.s) {
                IconTile(symbol: "questionmark.folder.fill", tint: .gray, size: Metrics.appIconSmall)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Removed apps").lineLimit(1)
                        Spacer(minLength: Space.xs)
                        Text(result.totalBytes.byteString)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.textSecondary)
                    }
                    Text("\(result.items.count) leftover items")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + Space.xxs)
            .contentShape(Rectangle())
            .background(isSelected ? Color.rowSelected : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Files an app left behind (for an app in the Trash, or for apps that are gone),
/// with only what's provably the app's own checked from the start.
private struct LeftoversView: View {
    let icon: Image?
    let title: Text
    let message: Text
    let result: ModuleResult
    let preselected: Set<URL>
    let model: AppModel
    let finished: (TrashOutcome) -> Void

    @ViewState private var checked: Set<URL>?
    @ViewState private var isMoving = false

    private var checkedURLs: Binding<Set<URL>> {
        Binding(get: { checked ?? preselected }, set: { checked = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.m) {
                if let icon {
                    icon.resizable()
                        .frame(width: Metrics.appIconLarge, height: Metrics.appIconLarge)
                        .accessibilityHidden(true)
                } else {
                    IconTile(symbol: "questionmark.folder.fill", tint: .gray, size: Metrics.appIconLarge)
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    title.font(.title2)
                    message
                        .foregroundStyle(.textSecondary)
                        .lineLimit(3)
                }
            }
            .padding(Metrics.windowPadding)
            ItemTable(items: result.items, checked: checkedURLs, home: model.home)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    TrashBar(selected: result.items.filter { checkedURLs.wrappedValue.contains($0.url) }, isWorking: isMoving) {
                        Task { await moveChecked() }
                    }
                }
        }
    }

    private func moveChecked() async {
        isMoving = true
        let items = result.items.filter { checkedURLs.wrappedValue.contains($0.url) }
        let outcome = await TrashService.moveToTrash(items, home: model.home, applicationRoots: model.applicationRoots)
        model.forget(outcome.moved)
        checked = checkedURLs.wrappedValue.subtracting(outcome.moved)
        isMoving = false
        finished(outcome)
    }
}

/// An app the user dragged to the Trash that left files behind.
private struct TrashedAppRow: View {
    let trashed: TrashedApp
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Space.s) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: trashed.app.url.path))
                    .resizable()
                    .frame(width: Metrics.appIconSmall, height: Metrics.appIconSmall)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white, .red)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: trashed.app.name).lineLimit(1)
                        Spacer(minLength: Space.xs)
                        Text(trashed.leftovers.totalBytes.byteString)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.textSecondary)
                    }
                    Text("In the Trash, left files behind")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + Space.xxs)
            .contentShape(Rectangle())
            .background(isSelected ? Color.rowSelected : .clear, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Why a dropped app can't be uninstalled.
private struct DropRejectionNotice: View {
    let rejection: TrashPolicy.Rejection
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("This app can't be removed here.")
                Text(verbatim: rejection.message)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
            }
            Spacer(minLength: Space.l)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Close"))
        }
        .padding(Space.m)
        .surface()
    }
}

private struct AppRow: View {
    let entry: AppsView.AppEntry
    let isSelected: Bool
    /// Another app has the same name, so show which bundle this is.
    let showsLocation: Bool
    let select: () -> Void

    @ViewState private var isHovered = false

    private var app: InstalledApp { entry.app }

    var body: some View {
        Button(action: select) {
            HStack(spacing: Space.s) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: Metrics.appIconSmall, height: Metrics.appIconSmall)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: app.name).lineLimit(1)
                        Spacer(minLength: Space.xs)
                        Text(entry.bytes.byteString)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.textSecondary)
                    }
                    if let update = entry.update {
                        Label(update.latestVersion, systemImage: "arrow.up.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .accessibilityLabel(Text("Update available: \(update.latestVersion)"))
                    }
                    Group {
                        if showsLocation {
                            Text(verbatim: app.url.path)
                                .truncationMode(.head)
                        } else if let lastUsed = entry.lastUsed {
                            Text("Last used \(lastUsed.formatted(.relative(presentation: .named)))")
                        } else {
                            Text("No usage record")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + Space.xxs)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.rowSelected : (isHovered ? Color.rowHover : .clear),
                in: RoundedRectangle(cornerRadius: Metrics.rowRadius)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One app and its leftovers. The app and anything not labelled "Review first" start checked,
/// because choosing to uninstall is the explicit request; review items stay unchecked.
private struct AppUninstallView: View {
    let app: InstalledApp
    let model: AppModel
    let finished: (TrashOutcome) -> Void

    @ViewState private var files: ModuleResult?
    @ViewState private var checked: Set<URL> = []
    @ViewState private var isMoving = false
    @ViewState private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(Metrics.windowPadding)
            if let update = model.appUpdates?[app.url] {
                UpdateBanner(update: update, model: model)
                    .padding([.horizontal, .bottom], Metrics.windowPadding)
            }
            if let files {
                ItemTable(items: files.items, checked: $checked, home: model.home)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        trashBar(files)
                    }
            } else {
                ProgressView("Looking for leftovers")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunning()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunning()
        }
    }

    private func trashBar(_ files: ModuleResult) -> some View {
        TrashBar(
            selected: files.items.filter { checked.contains($0.url) },
            isWorking: isMoving,
            disabledReason: app.isAppleApp ? "Apps that come with macOS can't be removed."
                : isRunning ? "Quit the app before removing it." : nil
        ) {
            Task { await moveChecked(files) }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: Metrics.appIconLarge, height: Metrics.appIconLarge)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(verbatim: app.name).font(.title2)
                Text(verbatim: [app.version, app.bundleIdentifier, DisplayNames.abbreviated(app.url, home: model.home)]
                    .compactMap { $0 }.joined(separator: "  ·  "))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                if let files {
                    Text("\(files.items.count) items, \(files.totalBytes.byteString)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                }
            }
            Spacer()
            if isRunning {
                Button("Quit App") { quitApp() }
                    .secondaryButtonStyle()
            }
        }
    }

    private func load() async {
        refreshRunning()
        let app = app, home = model.home
        let found = await Task.detached { LeftoverFinder.find(for: app, home: home) }.value
        files = found
        // Uninstalling is the explicit request: the app and everything provably its own start checked.
        checked = Set(found.items.filter { $0.url == app.url || $0.safety != .review }.map(\.url))
    }

    private var runningApps: [NSRunningApplication] {
        guard let id = app.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
    }

    private func refreshRunning() {
        isRunning = !runningApps.isEmpty
    }

    private func quitApp() {
        runningApps.forEach { $0.terminate() }
    }

    private func moveChecked(_ files: ModuleResult) async {
        isMoving = true
        model.noteUninstalled(app.bundleIdentifier)
        let items = files.items.filter { checked.contains($0.url) }
        let outcome = await TrashService.moveToTrash(items, home: model.home, applicationRoots: model.applicationRoots)
        model.forget(outcome.moved)
        self.files = files.removing(outcome.moved)
        checked.subtract(outcome.moved)
        isMoving = false
        finished(outcome)
    }
}

/// A newer version is available: say which, and offer the way that fits where the app came from.
private struct UpdateBanner: View {
    let update: AppUpdate
    let model: AppModel

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Version \(update.latestVersion) is available").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.textSecondary)
            }
            Spacer()
            Button(actionTitle, action: act)
                .prominentButtonStyle()
        }
        .padding(Space.m)
        .surface()
    }

    private var detail: LocalizedStringKey {
        switch update.source {
        case .sparkle: "You have \(update.installedVersion). The app installs updates itself: open it and choose Check for Updates."
        case .appStore: "You have \(update.installedVersion). It updates through the App Store."
        case .homebrew(_, _, managed: true): "You have \(update.installedVersion). Homebrew installed it, so Homebrew can update it."
        case .homebrew: "You have \(update.installedVersion). Download the new version from the developer."
        }
    }

    private var actionTitle: LocalizedStringKey {
        switch update.source {
        case .sparkle: "Open App"
        case .appStore: "Open App Store"
        case .homebrew(_, _, managed: true): "Update with Homebrew"
        case .homebrew: "Download Page"
        }
    }

    private func act() {
        switch update.source {
        case .sparkle:
            NSWorkspace.shared.openApplication(at: update.appURL, configuration: .init())
        case .appStore(let url):
            NSWorkspace.shared.open(url)
        case .homebrew(let token, _, managed: true):
            model.runBrew(["upgrade", "--cask", token], title: String(localized: "Updating \(token)"))
            NotificationCenter.default.post(name: .selectSidebarItem, object: SidebarItem.homebrew)
        case .homebrew(_, let homepage, _):
            if let homepage { NSWorkspace.shared.open(homepage) }
        }
    }
}
