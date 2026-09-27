import CleanerCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case storage
    case module(ModuleKind)
}

struct ContentView: View {
    @ViewState private var selection: SidebarItem? = .overview
    @ViewState private var model = AppModel()

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
                StorageView(model: model)
                    .navigationTitle(Text("Storage"))
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
        .onAppear {
            model.refreshVolume()
            #if DEBUG
            DebugLaunchOptions.apply(to: model) { selection = $0 }
            #endif
            model.watchApplicationFolders()
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
