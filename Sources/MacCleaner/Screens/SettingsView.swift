import CleanerCore
import SwiftUI

enum SettingsKeys {
    static let largeFileThreshold = "largeFileThreshold"
    static let oldDownloadMonths = "oldDownloadMonths"
}

/// The limits behind Large & Old Files. Changes apply on the next scan.
struct SettingsView: View {
    @AppStorage(SettingsKeys.largeFileThreshold) private var threshold = 500_000_000
    @AppStorage(SettingsKeys.oldDownloadMonths) private var months = 6

    private let thresholds = [100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000]

    var body: some View {
        Form {
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
}
