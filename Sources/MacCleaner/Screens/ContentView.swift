import CleanerCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case storage
    case systemData
    case backgroundItems
    case duplicates
    case homebrew
    case module(ModuleKind)
}

struct ContentView: View {
    @ViewState private var selection: SidebarItem? = .overview
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label {
                    Text("Overview")
                } icon: {
                    IconTile(symbol: "internaldrive.fill", tint: .gray, size: Metrics.sidebarIcon)
                }
                .tag(SidebarItem.overview)
                Label {
                    Text("Storage")
                } icon: {
                    IconTile(symbol: "chart.pie.fill", tint: .indigo, size: Metrics.sidebarIcon)
                }
                .tag(SidebarItem.storage)
                Label {
                    Text("System Data")
                } icon: {
                    IconTile(symbol: SystemDataView.symbol, tint: SystemDataView.tint, size: Metrics.sidebarIcon)
                }
                .tag(SidebarItem.systemData)
                Label {
                    Text("Background Items")
                } icon: {
                    IconTile(symbol: BackgroundItemsView.symbol, tint: BackgroundItemsView.tint, size: Metrics.sidebarIcon)
                }
                .tag(SidebarItem.backgroundItems)
                Label {
                    Text("Duplicates")
                } icon: {
                    IconTile(symbol: DuplicatesView.symbol, tint: DuplicatesView.tint, size: Metrics.sidebarIcon)
                }
                .tag(SidebarItem.duplicates)
                Label {
                    Text("Homebrew")
                } icon: {
                    IconTile(symbol: HomebrewView.symbol, tint: HomebrewView.tint, size: Metrics.sidebarIcon)
                }
                .badge(model.brewPackages.map { $0.filter(\.isOutdated).count }.flatMap { $0 > 0 ? Text("\($0)") : nil })
                .tag(SidebarItem.homebrew)
                Section {
                    ForEach(ModuleKind.allCases) { kind in
                        Label {
                            Text(kind.title)
                        } icon: {
                            IconTile(symbol: kind.symbol, tint: kind.tint, size: Metrics.sidebarIcon)
                        }
                        .badge(badge(for: kind))
                        .tag(SidebarItem.module(kind))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            switch selection ?? .overview {
            case .overview:
                OverviewView(model: model, openStorage: { selection = .storage }) { selection = .module($0) }
                    .navigationTitle(Text("Overview"))
            case .storage:
                StorageView(model: model) { selection = .systemData }
                    .navigationTitle(Text("Storage"))
            case .systemData:
                SystemDataView(model: model)
                    .navigationTitle(Text("System Data"))
            case .backgroundItems:
                BackgroundItemsView(model: model)
                    .navigationTitle(Text("Background Items"))
            case .duplicates:
                DuplicatesView(model: model)
                    .navigationTitle(Text("Duplicates"))
            case .homebrew:
                HomebrewView(model: model)
                    .navigationTitle(Text("Homebrew"))
            case .module(.apps):
                AppsView(model: model)
                    .navigationTitle(Text(ModuleKind.apps.title))
            case .module(let kind):
                ModuleDetailView(kind: kind, model: model)
                    .id(kind)
                    .navigationTitle(Text(kind.title))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { scanButton }
        }
        .frame(minWidth: Metrics.minWindow.width, minHeight: Metrics.minWindow.height)
        .onReceive(NotificationCenter.default.publisher(for: .selectSidebarItem)) { note in
            if let item = note.object as? SidebarItem { selection = item }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTrashedApp)) { note in
            guard let path = note.object as? String else { return }
            model.requestedTrashedApp = URL(fileURLWithPath: path)
            selection = .module(.apps)
        }
        .onAppear {
            model.start()
            #if DEBUG
            DebugLaunchOptions.apply(to: model) { selection = $0 }
            #endif
        }
    }

    /// Size found by the last scan, so the sidebar doubles as a summary.
    private func badge(for kind: ModuleKind) -> Text? {
        guard kind.isSized, let result = model.results[kind], result.totalBytes > 0 else { return nil }
        return Text(result.totalBytes.byteString)
    }

    @ViewBuilder private var scanButton: some View {
        if model.isScanning {
            Button(action: model.cancelScan) {
                Label {
                    Text("Cancel")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut(.cancelAction)
            .help(Text("Stop scanning"))
        } else {
            Button {
                model.scan()
            } label: {
                Label("Scan", systemImage: "sparkle.magnifyingglass")
                    .labelStyle(.titleAndIcon)
            }
            .prominentButtonStyle()
            .keyboardShortcut("r")
            .help(Text("Scan every module (⌘R)"))
        }
    }
}
