import SwiftUI

/// Empties the Trash after a confirmation that says plainly it can't be undone.
struct EmptyTrashButton: View {
    let model: AppModel

    @ViewState private var isConfirming = false
    @ViewState private var error: String?

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            if model.isEmptyingTrash {
                ProgressView().controlSize(.small)
            } else {
                Text("Empty Trash…")
            }
        }
        .disabled(model.isEmptyingTrash || model.trashBytes == 0)
        .confirmationDialog(Text("Empty the Trash?"), isPresented: $isConfirming) {
            Button(role: .destructive) {
                Task { error = await model.emptyTrash() }
            } label: {
                if let bytes = model.trashBytes {
                    Text("Empty Trash (\(bytes.byteString))")
                } else {
                    Text("Empty Trash")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash is deleted permanently. This can't be undone.")
        }
        .alert(Text("The Trash couldn't be emptied."), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(verbatim: error ?? "")
        }
    }
}

/// The Trash as a line on the overview: how much it holds, and the way to free it.
struct TrashCard: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            IconTile(symbol: "trash.fill", tint: .gray, size: 32)
            VStack(alignment: .leading, spacing: Space.xxs) {
                if let bytes = model.trashBytes {
                    Text("Trash: \(bytes.byteString)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } else {
                    Text("Trash")
                }
                Text("Items you move to the Trash still use space until it's emptied.")
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
            }
            Spacer(minLength: Space.l)
            Button("Open Trash", action: TrashService.openTrash)
                .secondaryButtonStyle()
            EmptyTrashButton(model: model)
                .secondaryButtonStyle()
        }
        .padding(Space.l)
        .surface()
        .accessibilityElement(children: .contain)
    }
}
