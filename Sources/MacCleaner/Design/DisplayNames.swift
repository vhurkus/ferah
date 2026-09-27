import AppKit

/// Human names for found items: "com.spotify.client" reads as "Spotify" when that app is installed.
@MainActor
enum DisplayNames {
    private static var cache: [URL: String] = [:]

    static func name(for url: URL) -> String {
        if let cached = cache[url] { return cached }
        let fileName = url.lastPathComponent
        var name = FileManager.default.displayName(atPath: url.path)
        let looksLikeBundleID = fileName.split(separator: ".").count >= 3 && !fileName.contains(" ")
        if looksLikeBundleID, url.pathExtension != "app",
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fileName) {
            name = "\(FileManager.default.displayName(atPath: app.path)) (\(fileName))"
        }
        cache[url] = name
        return name
    }

    /// Parent folder with the home folder shortened to "~".
    static func location(of url: URL, home: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        return parent.hasPrefix(home.path) ? "~" + parent.dropFirst(home.path.count) : parent
    }
}
