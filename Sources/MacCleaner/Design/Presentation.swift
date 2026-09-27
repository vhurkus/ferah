import CleanerCore
import SwiftUI

extension SafetyLabel {
    var title: LocalizedStringKey {
        switch self {
        case .regenerates: "Rebuilt automatically"
        case .safe: "Safe to remove"
        case .appData: "App's own data"
        case .review: "Review first"
        }
    }

    var symbol: String {
        switch self {
        case .regenerates: "arrow.clockwise"
        case .safe: "checkmark.circle"
        case .appData: "shippingbox"
        case .review: "eye"
        }
    }

    var iconColor: Color {
        switch self {
        case .regenerates: .regenIcon
        case .safe: .safeIcon
        case .appData: .regenIcon
        case .review: .reviewIcon
        }
    }
}

extension ModuleKind {
    var title: LocalizedStringKey {
        switch self {
        case .caches: "Caches & Logs"
        case .developer: "Developer Files"
        case .largeFiles: "Large & Old Files"
        case .apps: "Applications"
        }
    }

    var symbol: String {
        switch self {
        case .caches: "tray.full.fill"
        case .developer: "hammer.fill"
        case .largeFiles: "doc.text.magnifyingglass"
        case .apps: "square.grid.2x2.fill"
        }
    }

    /// Identity color of the module's icon tile; never the only carrier of meaning.
    var tint: Color {
        switch self {
        case .caches: .blue
        case .developer: .purple
        case .largeFiles: .orange
        case .apps: .teal
        }
    }

    /// What the module looks at, stated as the scanner's actual rules.
    var explanation: LocalizedStringKey {
        switch self {
        case .caches: "App caches and logs in your Library. Apps recreate their caches when needed."
        case .developer: "Xcode build data, package manager caches, Docker data and node_modules folders in your projects."
        case .largeFiles: "Large files in your home folders, and downloads you haven't opened in months. Set the limits in Settings (⌘,)."
        case .apps: "Apps you installed, with the files they leave in your Library."
        }
    }

    func countText(_ count: Int) -> Text {
        switch self {
        case .caches, .developer: Text("\(count) items")
        case .largeFiles: Text("\(count) files")
        case .apps: Text("\(count) apps")
        }
    }
}

extension Int64 {
    var byteString: String { formatted(.byteCount(style: .file)) }
}
