import AppKit
import CleanerCore
import SwiftUI

/// One-click versions of repairs macOS only offers in Terminal. Each says what it runs.
struct MaintenanceView: View {
    let model: AppModel

    static let symbol = "wrench.and.screwdriver.fill"
    static let tint = Color.gray

    @ViewState private var stale: [String]?
    @ViewState private var running: String?
    @ViewState private var results: [String: String] = [:]
    @ViewState private var confirmingSpotlight = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Maintenance").font(.system(.title, design: .rounded, weight: .bold))
                    Text("Fixes for common annoyances, using macOS's own tools. Run one only when you have the problem it fixes.")
                        .foregroundStyle(.textSecondary)
                }
                ToolCard(
                    id: "openwith", symbol: "rectangle.stack.badge.minus", tint: .blue,
                    title: Text("Clean up the Open With menu"),
                    detail: staleDetail,
                    command: "lsregister -u …", needsPassword: false,
                    actionTitle: stale.map { $0.isEmpty ? "Check Again" : "Remove \($0.count) Entries" } ?? "Check",
                    running: running, result: results["openwith"]
                ) {
                    Task { await cleanOpenWith() }
                }
                ToolCard(
                    id: "dns", symbol: "network", tint: .teal,
                    title: Text("Flush the DNS cache"),
                    detail: Text("Helps when a website moved to a new server but your Mac still goes to the old one."),
                    command: "dscacheutil -flushcache; killall -HUP mDNSResponder", needsPassword: true,
                    actionTitle: "Flush", running: running, result: results["dns"]
                ) {
                    Task { await runAdmin("dns", Maintenance.flushDNS, done: String(localized: "DNS cache flushed.")) }
                }
                ToolCard(
                    id: "spotlight", symbol: "magnifyingglass", tint: .purple,
                    title: Text("Rebuild the Spotlight index"),
                    detail: Text("Helps when Spotlight misses files you know are there. Searching stays incomplete while it rebuilds, which can take an hour or more."),
                    command: "mdutil -E /", needsPassword: true,
                    actionTitle: "Rebuild…", running: running, result: results["spotlight"]
                ) {
                    confirmingSpotlight = true
                }
                ToolCard(
                    id: "thumbnails", symbol: "photo.on.rectangle", tint: .orange,
                    title: Text("Reset Quick Look thumbnails"),
                    detail: Text("Helps when Finder shows old or wrong previews for files."),
                    command: "qlmanage -r cache", needsPassword: false,
                    actionTitle: "Reset", running: running, result: results["thumbnails"]
                ) {
                    Task { await resetThumbnails() }
                }
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(Text("Rebuild the Spotlight index?"), isPresented: $confirmingSpotlight) {
            Button("Rebuild") {
                Task { await runAdmin("spotlight", Maintenance.rebuildSpotlight,
                                      done: String(localized: "Spotlight is rebuilding its index in the background.")) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Spotlight forgets everything it indexed and starts over. Until it's done, searches in Spotlight, Finder and Mail miss results.")
        }
    }

    private var staleDetail: Text {
        guard let stale else {
            return Text("Removes apps that are gone or in the Trash from the list macOS uses for Open With and Spotlight, so they stop showing up twice.")
        }
        if stale.isEmpty { return Text("No leftover entries: every app macOS knows about is still there.") }
        let examples = stale.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return Text("\(stale.count) entries point to apps that are gone or in the Trash, such as \(examples).")
    }

    private func cleanOpenWith() async {
        running = "openwith"
        defer { running = nil }
        guard let found = stale, !found.isEmpty else {
            stale = await Maintenance.staleRegistrations()
            results["openwith"] = nil
            return
        }
        let result = await Maintenance.unregister(found)
        stale = await Maintenance.staleRegistrations()
        results["openwith"] = result.succeeded
            ? String(localized: "Removed \(found.count - (stale?.count ?? 0)) entries. Apps you open again are added back automatically.")
            : String(localized: "Couldn't finish: \(result.error)")
    }

    private func runAdmin(_ id: String, _ commands: [[String]], done: String) async {
        running = id
        defer { running = nil }
        let error = await AdminRunner.run(commands, prompt: String(localized: "Ferah wants to run a maintenance task."))
        results[id] = error ?? done
    }

    private func resetThumbnails() async {
        running = "thumbnails"
        defer { running = nil }
        let command = Maintenance.resetThumbnails
        let result = await ProcessRunner().run(command[0], Array(command.dropFirst()))
        results["thumbnails"] = result.succeeded ? String(localized: "Thumbnails reset. Finder makes new ones as you browse.") : result.error
    }
}

private struct ToolCard: View {
    let id: String
    let symbol: String
    let tint: Color
    let title: Text
    let detail: Text
    let command: String
    let needsPassword: Bool
    let actionTitle: LocalizedStringKey
    let running: String?
    let result: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.m) {
                IconTile(symbol: symbol, tint: tint, size: 40)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    title.font(.headline)
                    detail.font(.callout).foregroundStyle(.textSecondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s) {
                        Text(verbatim: command).font(.caption.monospaced()).foregroundStyle(.textSecondary)
                        if needsPassword {
                            Label("Asks for your password", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.textSecondary)
                        }
                    }
                }
                Spacer(minLength: Space.l)
                if running == id {
                    ProgressView().controlSize(.small)
                } else {
                    Button(actionTitle, action: action)
                        .secondaryButtonStyle()
                        .disabled(running != nil)
                }
            }
            if let result {
                Label(result, systemImage: "checkmark.circle")
                    .font(.callout)
                    .padding(.leading, 40 + Space.m)
            }
        }
        .padding(Space.l)
        .surface()
    }
}
