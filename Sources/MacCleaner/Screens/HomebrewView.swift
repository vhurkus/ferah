import AppKit
import CleanerCore
import SwiftUI

/// What Homebrew installed, what's out of date, and what's broken, with the brew command for each fix.
struct HomebrewView: View {
    let model: AppModel

    static let symbol = "mug.fill"
    static let tint = Color.orange

    @ViewState private var pendingUninstall: BrewPackage?
    /// A cask whose app is gone that Homebrew couldn't uninstall: its record can be dropped instead.
    @ViewState private var forgettable: BrewPackage?
    @ViewState private var forgetMessage: String?
    @ViewState private var showsDependencies = false

    var body: some View {
        Group {
            if model.homebrew == nil {
                EmptyStateHero(
                    symbol: Self.symbol, tint: Self.tint, title: Text("Homebrew isn't installed"),
                    message: Text("Homebrew installs command-line tools and apps. Ferah shows what it installed and keeps it up to date."),
                    actionTitle: "Visit brew.sh"
                ) {
                    if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) }
                }
            } else if let packages = model.brewPackages {
                content(packages)
            } else {
                EmptyStateHero(
                    symbol: Self.symbol, tint: Self.tint, title: Text("Homebrew"),
                    message: Text("See the apps and tools you installed with Homebrew, update them, and fix the ones whose app is gone."),
                    places: ["Apps (casks)", "Command-line tools", "Updates", "Old versions"],
                    actionTitle: model.isLoadingBrew ? "Looking…" : "Show Homebrew Packages",
                    isWorking: model.isLoadingBrew, action: model.loadHomebrew
                )
            }
        }
        .confirmationDialog(
            Text("Uninstall \(pendingUninstall?.displayName ?? "")?"),
            isPresented: Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } }),
            presenting: pendingUninstall
        ) { package in
            Button("Uninstall", role: .destructive) {
                forgettable = package.isAppMissing ? package : nil
                forgetMessage = nil
                model.runBrew(Homebrew.uninstallArguments(package), title: String(localized: "Uninstalling \(package.displayName)"))
            }
            Button("Cancel", role: .cancel) {}
        } message: { package in
            Text(package.kind == .cask
                 ? "Homebrew removes the app. Its files in your Library stay; review them afterwards under Applications › Removed apps."
                 : "Homebrew removes this tool. Other tools that need it may stop working.")
        }
    }

    private func content(_ packages: [BrewPackage]) -> some View {
        let missing = packages.filter(\.isAppMissing)
        let outdated = packages.filter(\.isOutdated)
        let casks = packages.filter { $0.kind == .cask && !$0.isAppMissing }
        let tools = packages.filter { $0.kind == .formula && $0.isRequested }
        let dependencies = packages.filter { $0.kind == .formula && !$0.isRequested }
        let isBusy = model.brewConsole.isRunning

        return ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header(casks: casks.count + missing.count, tools: tools.count, outdated: outdated.count, isBusy: isBusy)
                BrewConsoleView(console: model.brewConsole)
                if let package = forgettable, model.brewConsole.succeeded == false {
                    forgetCard(package)
                }
                if let forgetMessage {
                    Label(forgetMessage, systemImage: "info.circle")
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surface()
                }

                if !missing.isEmpty {
                    section(Text("App missing"), note: Text("Homebrew still lists these, but their app is gone. Reinstall it, or remove it from Homebrew.")) {
                        ForEach(missing) { package in
                            PackageRow(package: package) {
                                Button("Reinstall") {
                                    model.runBrew(Homebrew.reinstallArguments(package), title: String(localized: "Reinstalling \(package.displayName)"))
                                }
                                Button("Remove") { pendingUninstall = package }
                            }
                        }
                    }
                }
                if !outdated.isEmpty {
                    section(Text("Updates"), note: nil) {
                        ForEach(outdated) { package in
                            PackageRow(package: package) {
                                Button("Update") {
                                    model.runBrew(Homebrew.upgradeArguments(package), title: String(localized: "Updating \(package.displayName)"))
                                }
                            }
                        }
                    }
                }
                if let bytes = model.brewCleanupBytes, bytes > 0 {
                    HStack(spacing: Space.m) {
                        IconTile(symbol: "archivebox.fill", tint: .brown, size: 36)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text("Old versions and downloads: \(bytes.byteString)").font(.headline)
                            Text("Homebrew keeps previous versions and installers. Cleaning up removes them.")
                                .font(.callout)
                                .foregroundStyle(.textSecondary)
                        }
                        Spacer()
                        Button("Clean Up") {
                            model.runBrew(Homebrew.cleanupArguments, title: String(localized: "Cleaning up Homebrew"))
                        }
                        .disabled(isBusy)
                    }
                    .padding(Space.l)
                    .surface()
                }
                section(Text("Apps"), note: nil) {
                    ForEach(casks) { package in
                        PackageRow(package: package) {
                            Button("Uninstall…") { pendingUninstall = package }
                        }
                    }
                }
                section(Text("Command-line tools"), note: nil) {
                    ForEach(tools) { package in
                        PackageRow(package: package) {
                            Button("Uninstall…") { pendingUninstall = package }
                        }
                    }
                }
                if !dependencies.isEmpty {
                    DisclosureGroup(isExpanded: $showsDependencies) {
                        VStack(spacing: Space.s) {
                            ForEach(dependencies) { PackageRow(package: $0) { EmptyView() } }
                        }
                        .padding(.top, Space.s)
                    } label: {
                        HStack {
                            Text("\(dependencies.count) dependencies").font(.headline)
                            Spacer()
                            Button("Remove Unused") {
                                model.runBrew(Homebrew.autoremoveArguments, title: String(localized: "Removing unused dependencies"))
                            }
                            .disabled(isBusy)
                            .help(Text("Removes dependencies nothing needs anymore (brew autoremove)."))
                        }
                    }
                }
            }
            .secondaryButtonStyle()
            .padding(Metrics.windowPadding)
            .frame(maxWidth: Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    /// Homebrew runs a cask's uninstall steps even when its app is gone, and some of them fail then
    /// (quitting an app that isn't there). Dropping Homebrew's record is what's left to do.
    private func forgetCard(_ package: BrewPackage) -> some View {
        HStack(spacing: Space.m) {
            IconTile(symbol: "bandage.fill", tint: .orange, size: 36)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Homebrew couldn't uninstall \(package.displayName)").font(.headline)
                Text("Its app is already gone, and one of the cask's uninstall steps fails without it. Ferah can drop Homebrew's record of it instead; the record goes to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(3)
            }
            Spacer()
            Button("Forget in Homebrew") { Task { await forget(package) } }
                .prominentButtonStyle()
        }
        .padding(Space.l)
        .surface()
    }

    private func forget(_ package: BrewPackage) async {
        guard let record = model.homebrew?.caskroomRecord(for: package) else {
            forgetMessage = String(localized: "Homebrew has no record of \(package.displayName) anymore.")
            forgettable = nil
            model.loadHomebrew()
            return
        }
        do {
            _ = try await NSWorkspace.shared.recycle([record])
            forgetMessage = String(localized: "Homebrew no longer lists \(package.displayName).")
        } catch {
            forgetMessage = String(localized: "Couldn't remove Homebrew's record of \(package.displayName): \(error.localizedDescription)")
        }
        forgettable = nil
        model.brewConsole.dismiss()
        model.loadHomebrew()
    }

    private func header(casks: Int, tools: Int, outdated: Int, isBusy: Bool) -> some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(outdated > 0 ? "\(outdated) updates available" : "Everything is up to date")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text("\(casks) apps and \(tools) tools installed with Homebrew.")
                    .foregroundStyle(.textSecondary)
            }
            Spacer()
            Button("Check for Updates") {
                model.runBrew(Homebrew.updateArguments, title: String(localized: "Checking for updates"))
            }
            .disabled(isBusy)
            if outdated > 0 {
                Button("Update All") {
                    model.runBrew(Homebrew.upgradeArguments(nil), title: String(localized: "Updating everything"))
                }
                .prominentButtonStyle()
                .disabled(isBusy)
            }
        }
    }

    private func section<Content: View>(_ title: Text, note: Text?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            title.font(.headline)
            if let note { note.font(.callout).foregroundStyle(.textSecondary) }
            // One brew command at a time.
            VStack(spacing: Space.s) { content() }
                .disabled(model.brewConsole.isRunning)
        }
    }
}

/// One package: icon, name, version (and the new one), with actions on the right.
private struct PackageRow<Actions: View>: View {
    let package: BrewPackage
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: Space.m) {
            icon
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    Text(verbatim: package.displayName).font(.headline)
                    if package.kind == .cask, package.displayName != package.token {
                        Text(verbatim: package.token).font(.caption).foregroundStyle(.textSecondary)
                    }
                    if package.isAppMissing {
                        Label("App missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.reviewIcon)
                    }
                }
                if let summary = package.summary {
                    Text(verbatim: summary).font(.callout).foregroundStyle(.textSecondary).lineLimit(1)
                }
                HStack(spacing: Space.s) {
                    Text(verbatim: package.installedVersion).monospacedDigit()
                    if let latest = package.latestVersion {
                        Image(systemName: "arrow.right").accessibilityLabel(Text("to"))
                        Text(verbatim: latest).monospacedDigit().fontWeight(.semibold)
                    } else if package.autoUpdates {
                        Text("Updates itself")
                    }
                }
                .font(.caption)
                .foregroundStyle(.textSecondary)
            }
            Spacer(minLength: Space.l)
            actions()
        }
        .padding(Space.m)
        .surface()
    }

    @ViewBuilder private var icon: some View {
        if let path = package.appPath, !package.isAppMissing {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
        } else {
            IconTile(symbol: package.kind == .cask ? "app.dashed" : "terminal.fill",
                     tint: package.kind == .cask ? .gray : .indigo, size: 36)
        }
    }
}

/// The running (or last) brew command and its output.
private struct BrewConsoleView: View {
    let console: BrewConsole

    var body: some View {
        if console.isRunning || console.succeeded != nil {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    if console.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: console.succeeded == true ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(console.succeeded == true ? Color.safeIcon : Color.reviewIcon)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: console.title).font(.headline)
                    Text(verbatim: console.command).font(.caption.monospaced()).foregroundStyle(.textSecondary)
                    Spacer()
                    if !console.isRunning {
                        Button(action: console.dismiss) { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Close"))
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(verbatim: console.output.isEmpty ? "…" : console.output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("end")
                    }
                    .frame(height: 140)
                    .onChange(of: console.output) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .padding(Space.s)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
                if console.needsTerminal {
                    HStack(spacing: Space.s) {
                        Text("This one needs your password, which only Terminal can ask for. Paste the command there.")
                            .font(.callout)
                        Spacer()
                        Button("Copy Command", action: console.copyCommand)
                        Button("Open Terminal", action: console.openTerminal)
                    }
                }
            }
            .padding(Space.l)
            .surface()
        }
    }
}
