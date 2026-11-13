import SwiftUI

@MainActor
struct GroupCreateFormView: View {
    @Binding var name: String
    let isSubmitting: Bool
    let onSubmit: (String) -> Void

    @FocusState private var isNameFocused: Bool

    private var normalizedName: String? {
        GroupNameInput.normalize(name)
    }

    private var validationMessage: String? {
        guard !name.isEmpty, normalizedName == nil else { return nil }
        return "Use visible characters for the name, up to 80."
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupScreenHeader(title: "Create Group")

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupMonogram(name: name.isEmpty ? "Group" : name, size: 88)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)

                    Label("Private — only you", systemImage: "lock")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(KeepsakeStyle.ink)

                    Text("Group name")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(KeepsakeStyle.secondaryInk)

                    TextField(
                        "Group name",
                        text: $name,
                        prompt: Text("Group name").foregroundStyle(KeepsakeStyle.secondaryInk)
                    )
                        .font(.body)
                        .foregroundStyle(KeepsakeStyle.ink)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .disabled(isSubmitting)
                        .onSubmit(submit)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 54)
                        .background(
                            KeepsakeStyle.fieldFill,
                            in: RoundedRectangle(cornerRadius: KeepsakeStyle.controlRadius)
                        )
                        .accessibilityLabel("Group name")

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(KeepsakeStyle.destructive)
                    }

                    Text(isSubmitting
                        ? "Creating your group. This screen updates when your account confirms it."
                        : "Only you will be in this group. The name is private to your account.")
                        .font(.footnote)
                        .foregroundStyle(KeepsakeStyle.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            GroupPrimaryButton(
                title: isSubmitting ? "Creating group…" : "Create group",
                isWorking: isSubmitting,
                isEnabled: normalizedName != nil,
                action: submit
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { KeepsakeStyle.canvas.ignoresSafeArea() }
    }

    private func submit() {
        guard let normalizedName else { return }
        isNameFocused = false
        onSubmit(normalizedName)
    }
}
