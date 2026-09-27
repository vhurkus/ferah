import CleanerCore
import ServiceManagement
import SwiftUI

enum SettingsKeys {
    static let largeFileThreshold = "largeFileThreshold"
    static let oldDownloadMonths = "oldDownloadMonths"
    static let showInMenuBar = "showInMenuBar"
    static let warnLowSpace = "warnLowSpace"
    static let lastLowSpaceWarning = "lastLowSpaceWarning"
}

/// The limits behind Large & Old Files. Changes apply on the next scan.
struct SettingsView: View {
    @AppStorage(SettingsKeys.largeFileThreshold) private var threshold = 500_000_000
    @AppStorage(SettingsKeys.oldDownloadMonths) private var months = 6

    private let thresholds = [100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000]

    @AppStorage(SettingsKeys.showInMenuBar) private var showInMenuBar = true
    @AppStorage(SettingsKeys.warnLowSpace) private var warnLowSpace = true
    @ViewState private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show Ferah in the menu bar", isOn: $showInMenuBar)
                Toggle("Warn when disk space runs low", isOn: $warnLowSpace)
                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
                if let loginError {
                    Text(verbatim: loginError).font(.callout).foregroundStyle(.reviewIcon)
                }
            } header: {
                Text("General")
            } footer: {
                Text("While Ferah is in the menu bar it keeps running after you close its window, so it can tell you when an app you drag to the Trash leaves files behind.")
                    .foregroundStyle(.textSecondary)
            }
            Section {
                Picker("Large files are at least", selection: $threshold) {
                    ForEach(thresholds, id: \.self) { Text(Int64($0).byteString).tag($0) }
                }
                Picker("Downloads count as old after", selection: $months) {
                    Text("3 months").tag(3)
                    Text("6 months").tag(6)
                    Text("1 year").tag(12)
                    Text("Never").tag(0)
                }
            } header: {
                Text("Large & Old Files")
            } footer: {
                Text("Ferah looks in every folder of your home folder except Library. Changes apply the next time you scan.")
                    .foregroundStyle(.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
