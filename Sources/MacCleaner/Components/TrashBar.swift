import CleanerCore
import SwiftUI

/// Bottom bar for a checkable list: what's selected, and the one primary action.
/// The action always asks for confirmation first.
struct TrashBar: View {
    let selected: [ScanItem]
    var isWorking = false
    var disabledReason: LocalizedStringKey?
    /// Extra things to know before confirming, shown in the confirmation dialog.
    var notes: [Text] = []
    let moveToTrash: () -> Void

    @ViewState private var isConfirming = false

    private var bytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }

    private var allNotes: [Text] {
        let adminCount = selected.filter { TrashService.needsAdministrator($0.url) }.count
        guard adminCount > 0 else { return notes }
        return notes + [Text("\(adminCount) items need an administrator password. Finder will ask for it once.")]
    }
    private var canMove: Bool { !selected.isEmpty && !isWorking && disabledReason == nil }

    private var trashButton: some View {
        Button {
            isConfirming = true
        } label: {
            Label {
                if selected.isEmpty {
                    Text("Move to Trash")
                } else {
                    Text("Move to Trash (\(bytes.byteString))").monospacedDigit()
                }
            } icon: {
                Image(systemName: "trash")
            }
            .labelStyle(.titleAndIcon)
        }
    }

    var body: some View {
        HStack(spacing: Space.m) {
            if let disabledReason {
                Text(disabledReason).foregroundStyle(.textSecondary)
            } else if selected.isEmpty {
                Text("Nothing selected").foregroundStyle(.textSecondary)
            } else {
                Text("\(selected.count) selected, \(bytes.byteString)")
                    .monospacedDigit()
            }
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            }
            // Prominent only when it can act; a disabled prominent button still reads as active in dark mode.
            if canMove {
                trashButton.prominentButtonStyle()
            } else {
                trashButton.secondaryButtonStyle().disabled(true)
            }
        }
        .controlSize(.large)
        .floatingBar()
        .confirmationDialog(
            Text("Move \(selected.count) items to the Trash?"),
            isPresented: $isConfirming
        ) {
            Button("Move to Trash (\(bytes.byteString))", action: moveToTrash)
            Button("Cancel", role: .cancel) {}
        } message: {
            allNotes.reduce(Text("You can put them back from the Trash. The space is freed when you empty the Trash.")) {
                $0 + Text(verbatim: "\n\n") + $1
            }
        }
    }
}

/// Result of the last move: what went, and anything that couldn't be moved (with the reason).
struct TrashResultBanner: View {
    let outcome: TrashOutcome
    /// When given, offers to empty the Trash right away: moving alone doesn't free the space.
    var model: AppModel?
    let dismiss: () -> Void

    @ViewState private var showsFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: outcome.moved.isEmpty ? "info.circle" : "checkmark.circle.fill")
                    .foregroundStyle(outcome.moved.isEmpty ? Color.textSecondary : .safeIcon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    if !outcome.moved.isEmpty {
                        Text("Moved \(outcome.moved.count) items (\(outcome.movedBytes.byteString)) to the Trash.")
                        Text("The space is freed when you empty the Trash.")
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                    }
                    if !outcome.failures.isEmpty {
                        Text("\(outcome.failures.count) items couldn't be moved.")
                    }
                }
                Spacer(minLength: Space.l)
                if !outcome.moved.isEmpty {
                    Button("Open Trash", action: TrashService.openTrash)
                    if let model {
                        EmptyTrashButton(model: model)
                    }
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Close"))
            }
            if !outcome.failures.isEmpty {
                DisclosureGroup(isExpanded: $showsFailures) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(outcome.failures) { failure in
                            Text(verbatim: "\(failure.url.lastPathComponent): \(failure.reason)")
                                .font(.callout)
                                .foregroundStyle(.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Details").font(.callout)
                }
            }
        }
        .padding(Space.m)
        .surface()
    }
}
