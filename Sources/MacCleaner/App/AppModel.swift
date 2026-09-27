import CleanerCore
import Foundation
import Observation

/// Scan state shared by every screen.
@MainActor @Observable
final class AppModel {
    /// One model for the window and the menu bar, so both show the same state.
    static let shared = AppModel()

    private var hasStarted = false

    /// Starts what runs for as long as the app does: folder watchers and the disk space check.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshVolume()
        watchApplicationFolders()
        watchTrash()
        Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDiskSpace() }
        }
        checkDiskSpace()
    }

    /// Warns once a day at most when free space drops below 10% of the disk.
    func checkDiskSpace() {
        refreshVolume()
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SettingsKeys.warnLowSpace) as? Bool ?? true, let volume else { return }
        guard volume.availableBytes < volume.totalBytes / 10 else { return }
        let last = defaults.object(forKey: SettingsKeys.lastLowSpaceWarning) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 24 * 60 * 60 else { return }
        defaults.set(Date.now, forKey: SettingsKeys.lastLowSpaceWarning)
        Notifier.lowDiskSpace(available: volume.availableBytes)
    }

    private(set) var home = FileManager.default.homeDirectoryForCurrentUser
    private(set) var applicationRoots = Scanner.defaultApplicationRoots(home: FileManager.default.homeDirectoryForCurrentUser)

    #if DEBUG
    /// Points every scan and every trash check at a fixture folder instead of the real home.
    func useFixtureHome(_ url: URL) {
        home = url
        applicationRoots = [url.appending(path: "Applications")]
        results = [:]
        storageMap = nil
        lastScan = nil
    }
    #endif

    private(set) var volume: VolumeInfo?
    private(set) var volumeUnavailable = false
    /// Results survive a rescan, so screens don't go blank while scanning again.
    private(set) var results: [ModuleKind: ModuleResult] = [:]
    private(set) var scanning: Set<ModuleKind> = []
    private(set) var lastScan: Date?

    private var scanTask: Task<Void, Never>?

    var isScanning: Bool { scanTask != nil }

    private var sizedResults: [ModuleResult]? {
        let sized = ModuleKind.allCases.filter(\.isSized)
        guard sized.allSatisfy({ results[$0] != nil }) else { return nil }
        return sized.compactMap { results[$0] }
    }

    /// Rebuilt-automatically and safe bytes; nil until every sized module has a result.
    var safeBytes: Int64? { sizedResults?.reduce(0) { $0 + $1.safeBytes } }
    /// Bytes only the user can decide about; never counted as removable space.
    var reviewBytes: Int64? { sizedResults?.reduce(0) { $0 + $1.reviewBytes } }

    var hasUnreadableFolders: Bool { results.values.contains { !$0.unreadable.isEmpty } }

    /// Whether macOS lets the app read protected folders (Mail, Safari, other apps' containers).
    private(set) var hasFullDiskAccess = true

    /// Full Disk Access can't be queried directly; reading a file only it unlocks is the reliable test.
    static func checkFullDiskAccess() -> Bool {
        let probe = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: probe.path) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: probe) else { return false }
        try? handle.close()
        return true
    }

    /// Size of the Trash; nil until measured or when macOS doesn't let the app read it.
    private(set) var trashBytes: Int64?
    private(set) var isEmptyingTrash = false

    func refreshVolume() {
        hasFullDiskAccess = Self.checkFullDiskAccess()
        do {
            volume = try VolumeInfo.current()
            volumeUnavailable = false
        } catch {
            volumeUnavailable = true
        }
        Task { trashBytes = await TrashService.trashSize() }
    }

    /// Permanently deletes what's in the Trash. Returns an error message on failure.
    func emptyTrash() async -> String? {
        isEmptyingTrash = true
        defer { isEmptyingTrash = false }
        let error = await TrashService.emptyTrash()
        if error == nil, let map = storageMap {
            storageMap = map.removing(StorageAnalyzer.realURL(home).appending(path: ".Trash"))
        }
        refreshVolume()
        return error
    }

    /// Limits the user set in Settings.
    static var rules: ScanRules {
        var rules = ScanRules()
        let defaults = UserDefaults.standard
        let threshold = defaults.integer(forKey: SettingsKeys.largeFileThreshold)
        if threshold > 0 { rules.largeFileThreshold = Int64(threshold) }
        let months = defaults.object(forKey: SettingsKeys.oldDownloadMonths) as? Int ?? 6
        rules.oldDownloadAge = months > 0 ? TimeInterval(months) * 30 * 24 * 60 * 60 : nil
        return rules
    }

    func scan(_ kinds: [ModuleKind] = ModuleKind.allCases) {
        guard scanTask == nil else { return }
        let home = home, roots = applicationRoots, rules = Self.rules
        scanning = Set(kinds)

        scanTask = Task {
            await withTaskGroup(of: (ModuleKind, ModuleResult).self) { group in
                for kind in kinds {
                    group.addTask { (kind, Scanner.scan(kind, home: home, applicationRoots: roots, rules: rules)) }
                }
                for await (kind, result) in group {
                    if Task.isCancelled { break }
                    results[kind] = result
                    scanning.remove(kind)
                }
            }
            if !Task.isCancelled, kinds.count == ModuleKind.allCases.count { lastScan = .now }
            scanning = []
            scanTask = nil
            refreshVolume()
            if kinds.contains(.apps), !Task.isCancelled { findOrphans() }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: Apps dragged to the Trash

    /// Apps the user moved to the Trash outside Ferah that left files behind, newest first.
    private(set) var trashedApps: [TrashedApp] = []
    /// Set when a notification asks to show one of them.
    var requestedTrashedApp: URL?
    private var appsSeenInTrash: Set<String> = []
    private var trashWatcher: DispatchSourceFileSystemObject?
    private var pendingTrashCheck: Task<Void, Never>?
    /// Apps Ferah itself just uninstalled: no need to tell the user about their leftovers.
    private var uninstalledByFerah: [String: Date] = [:]

    private var trashFolder: URL { home.appending(path: ".Trash") }

    /// Notices apps dropped on the Trash in Finder. Needs Full Disk Access to read the Trash.
    func watchTrash() {
        guard trashWatcher == nil else { return }
        appsSeenInTrash = Set(TrashedAppFinder.appsInTrash(trashFolder).map(\.path))
        let descriptor = open(trashFolder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.trashChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        trashWatcher = source
    }

    func noteUninstalled(_ bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        uninstalledByFerah[bundleIdentifier] = .now
    }

    private func trashChanged() {
        pendingTrashCheck?.cancel()
        pendingTrashCheck = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let current = TrashedAppFinder.appsInTrash(trashFolder)
            let added = current.filter { !appsSeenInTrash.contains($0.path) }
            appsSeenInTrash = Set(current.map(\.path))
            // Put back or emptied: those are no longer "in the Trash".
            trashedApps.removeAll { !appsSeenInTrash.contains($0.app.url.path) }
            refreshVolume()

            let home = home
            for url in added {
                guard let found = await Task.detached(operation: { TrashedAppFinder.leftovers(of: url, home: home) }).value
                else { continue }
                if let id = found.app.bundleIdentifier, let date = uninstalledByFerah[id], date.timeIntervalSinceNow > -300 {
                    continue
                }
                trashedApps.insert(found, at: 0)
                Notifier.leftovers(of: found)
            }
        }
    }

    // MARK: Leftovers of removed apps

    /// Files named after apps that are no longer installed; nil until the apps scan has run.
    private(set) var orphans: ModuleResult?

    private func findOrphans() {
        guard let apps = results[.apps] else { return }
        let home = home
        let installed = Set(apps.items.compactMap { InstalledApp(url: $0.url).bundleIdentifier?.lowercased() })
        Task {
            orphans = await Task.detached { OrphanFinder.find(home: home, installedIdentifiers: installed) }.value
        }
    }

    // MARK: Homebrew

    /// nil when Homebrew isn't installed.
    let homebrew = Homebrew()
    let brewConsole = BrewConsole()
    private(set) var brewPackages: [BrewPackage]?
    private(set) var brewCleanupBytes: Int64?
    private(set) var isLoadingBrew = false

    func loadHomebrew() {
        guard let homebrew, !isLoadingBrew else { return }
        isLoadingBrew = true
        Task {
            async let packages = homebrew.installed()
            async let cleanup = homebrew.cleanupEstimate()
            brewPackages = await packages
            brewCleanupBytes = await cleanup
            isLoadingBrew = false
        }
    }

    func runBrew(_ arguments: [String], title: String) {
        guard let homebrew else { return }
        brewConsole.run(homebrew, arguments, title: title) { [weak self] in
            self?.loadHomebrew()
            self?.refreshVolume()
            // Apps came or went: refresh the app list and what's left of removed ones.
            if arguments.contains("--cask") || arguments == Homebrew.upgradeArguments(nil) { self?.scan([.apps]) }
        }
    }

    // MARK: Duplicates

    private(set) var duplicates: [DuplicateGroup]?
    /// Files looked at so far while searching; nil when not searching.
    private(set) var duplicateProgress: Int?
    private var duplicateTask: Task<Void, Never>?

    func findDuplicates() {
        guard duplicateTask == nil else { return }
        let roots = Scanner.largeFileRoots(home: home)
        duplicateProgress = 0
        duplicateTask = Task {
            let groups = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.find(in: roots) { count in
                    Task { @MainActor in if self.duplicateTask != nil { self.duplicateProgress = count } }
                }
            }.value
            if !Task.isCancelled { duplicates = groups }
            duplicateProgress = nil
            duplicateTask = nil
        }
    }

    func cancelDuplicateSearch() {
        duplicateTask?.cancel()
    }

    // MARK: Background items

    private(set) var backgroundItems: [BackgroundItem]?
    private(set) var isLoadingBackgroundItems = false

    func loadBackgroundItems() {
        guard !isLoadingBackgroundItems else { return }
        isLoadingBackgroundItems = true
        let home = home, roots = applicationRoots
        Task {
            backgroundItems = await Task.detached {
                let apps = Scanner.scan(.apps, home: home, applicationRoots: roots).items.map { InstalledApp(url: $0.url) }
                return await BackgroundItemFinder(home: home).find(installedApps: apps)
            }.value
            isLoadingBackgroundItems = false
        }
    }

    // MARK: System Data

    /// What hides in "System Data"; nil until inspected.
    private(set) var systemData: [SystemDataItem]?
    private(set) var isInspectingSystemData = false

    var systemDataInspector: SystemDataInspector { SystemDataInspector(home: home) }

    func inspectSystemData() {
        guard !isInspectingSystemData else { return }
        isInspectingSystemData = true
        let inspector = systemDataInspector
        Task {
            systemData = await Task.detached { await inspector.inspect() }.value
            isInspectingSystemData = false
            refreshVolume()
        }
    }

    // MARK: Storage

    private(set) var storageMap: StorageMap?
    /// Files measured so far while analyzing; nil when not analyzing.
    private(set) var storageProgress: Int?
    private var storageTask: Task<Void, Never>?

    var isAnalyzingStorage: Bool { storageTask != nil }

    /// Shared folders outside the home folder that often hold a lot (Xcode simulators, Homebrew).
    /// Measured to explain the disk, never offered for removal beyond what TrashPolicy allows.
    static let sharedStorageRoots = ["/Library", "/opt", "/usr/local"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// The home folder first, then application folders outside it, then shared folders.
    var storageRoots: [URL] {
        var roots = [home] + applicationRoots.filter { !$0.path.hasPrefix(home.path + "/") }
        #if DEBUG
        // A fixture home stays self-contained.
        if home != FileManager.default.homeDirectoryForCurrentUser { return roots }
        #endif
        roots += Self.sharedStorageRoots.filter { FileManager.default.fileExists(atPath: $0.path) }
        return roots
    }

    func analyzeStorage() {
        guard storageTask == nil else { return }
        let roots = storageRoots
        storageProgress = 0
        storageTask = Task {
            let map = await Task.detached(priority: .userInitiated) {
                StorageAnalyzer.map(roots) { count in
                    Task { @MainActor in
                        if self.storageTask != nil { self.storageProgress = count }
                    }
                }
            }.value
            if !Task.isCancelled { storageMap = map }
            storageProgress = nil
            storageTask = nil
            refreshVolume()
        }
    }

    func cancelStorageAnalysis() {
        storageTask?.cancel()
    }

    // MARK: Watching application folders

    private var folderWatchers: [DispatchSourceFileSystemObject] = []
    private var pendingAppsRescan: Task<Void, Never>?

    /// Rescans apps when something is installed or removed, so the list never goes stale.
    func watchApplicationFolders() {
        guard folderWatchers.isEmpty else { return }
        for root in applicationRoots {
            let descriptor = open(root.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.applicationFolderChanged() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            folderWatchers.append(source)
        }
    }

    private func applicationFolderChanged() {
        // Installers write in bursts; wait for them to settle.
        pendingAppsRescan?.cancel()
        pendingAppsRescan = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, results[.apps] != nil else { return }
            while isScanning {
                try? await Task.sleep(for: .seconds(1))
            }
            scan([.apps])
        }
    }

    /// Drops trashed items from every module, since an app's leftovers can also be listed as caches.
    func forget(_ urls: Set<URL>) {
        for (kind, result) in results {
            results[kind] = result.removing(urls)
        }
        orphans = orphans?.removing(urls)
        duplicates = duplicates?.compactMap { group in
            let copies = group.copies.filter { !urls.contains($0.url) }
            return copies.count > 1 ? DuplicateGroup(bytes: group.bytes, copies: copies) : nil
        }
        trashedApps = trashedApps
            .map { TrashedApp(app: $0.app, leftovers: $0.leftovers.removing(urls)) }
            .filter { !$0.leftovers.items.isEmpty }
        if var map = storageMap {
            for url in urls { map = map.removing(url) }
            storageMap = map
        }
        refreshVolume()
    }
}
