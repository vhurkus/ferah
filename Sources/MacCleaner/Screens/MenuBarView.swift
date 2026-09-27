import AppKit
import CleanerCore
import SwiftUI

/// The menu bar panel: free space at a glance, the Trash, and a way into the app.
struct MenuBarView: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let volume = model.volume {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: volume.name).font(.headline)
                    FigureText(text: Text("\(volume.availableBytes.byteString) free"), size: 26)
                    ProgressView(value: Double(volume.usedBytes), total: Double(max(volume.totalBytes, 1)))
                        .tint(volume.availableBytes < volume.totalBytes / 10 ? .orange : .accentColor)
                    Text("\(volume.usedBytes.byteString) of \(volume.totalBytes.byteString) used")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                }
            }
            if let bytes = model.trashBytes, bytes > 0 {
                Divider()
                HStack {
                    Label("Trash: \(bytes.byteString)", systemImage: "trash")
                    Spacer()
                    EmptyTrashButton(model: model)
                        .controlSize(.small)
                }
            }
            if !model.trashedApps.isEmpty {
                Divider()
                Button {
                    open(.module(.apps))
                } label: {
                    Label("\(model.trashedApps.count) trashed apps left files behind", systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Button("Open Ferah") { open(nil) }
                    .prominentButtonStyle()
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help(Text("Settings"))
                .accessibilityLabel(Text("Settings"))
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help(Text("Quit Ferah"))
                .accessibilityLabel(Text("Quit Ferah"))
            }
            .buttonStyle(.borderless)
        }
        .padding(Space.l)
        .frame(width: 300)
        .onAppear { model.refreshVolume() }
    }

    private func open(_ item: SidebarItem?) {
        openWindow(id: "main")
        NSApp.activate()
        if let item { NotificationCenter.default.post(name: .selectSidebarItem, object: item) }
    }
}

extension Notification.Name {
    static let selectSidebarItem = Notification.Name("FerahSelectSidebarItem")
}
