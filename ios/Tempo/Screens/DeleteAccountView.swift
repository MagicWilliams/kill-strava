import SwiftUI

/// The confirmation in front of `RunStore.deleteAccount` (#295).
///
/// One screen, one question, and the way out is the easy button. The copy names what goes
/// rather than saying "all your data", and names Apple Health as what stays, because Tempo
/// writes recorded runs there and this is the moment someone decides whether they are about
/// to lose their training history outright.
///
/// There is no undo to offer and no grace period: the function deletes the auth user, and
/// every table cascades off it. So the sheet asks once, plainly, and says so.
struct DeleteAccountView: View {
    /// Called when the athlete backs out. A deletion that lands never comes back through
    /// here: the launch gate flips to onboarding and takes this whole tree with it.
    let onCancel: () -> Void

    @EnvironmentObject private var store: RunStore
    @State private var deleting = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(AccountDeletion.Copy.title)
                        .font(Tokens.Font.display(30))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                    Text(AccountDeletion.Copy.body)
                        .font(Tokens.Font.ui(15))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure {
                        Text(failure)
                            .font(Tokens.Font.ui(14, .semibold))
                            .foregroundStyle(Tokens.Palette.danger)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 32)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 10) {
                // The safe choice carries the weight. Volt on "Delete everything" would be
                // the same button the app uses for Start and Confirm, which is the wrong
                // thing for the one action nothing can take back.
                PrimaryButton(title: AccountDeletion.Copy.cancel) { onCancel() }
                    .disabled(deleting)
                DestructiveButton(title: AccountDeletion.Copy.confirm, loading: deleting) {
                    delete()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Tokens.Palette.canvas.ignoresSafeArea())
        .interactiveDismissDisabled(deleting)
    }

    private func delete() {
        guard !deleting else { return }
        Task {
            deleting = true
            failure = nil
            let outcome = await store.deleteAccount()
            deleting = false
            // On a deletion this view is already on its way out with the rest of the tab
            // tree. The only thing left to do here is say when it did not happen.
            if outcome == .failed { failure = AccountDeletion.Copy.failure }
        }
    }
}

/// `SecondaryButton`'s shape in danger ink, for an action with no undo.
///
/// Private to this screen, and it stays that way until something else needs one: the design
/// system has no destructive button because, until now, the app had nothing to destroy.
private struct DestructiveButton: View {
    let title: String
    var loading = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small).tint(Tokens.Palette.danger)
                }
                Text(loading ? AccountDeletion.Copy.working : title)
                    .font(Tokens.Font.ui(16, .bold))
            }
            .foregroundStyle(Tokens.Palette.danger)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Tokens.Palette.elevated)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
            .motion(Motion.reveal, value: loading)
        }
        .buttonStyle(Pressable())
        .disabled(loading)
    }
}

#Preview {
    DeleteAccountView {}
        .environmentObject(RunStore())
        .preferredColorScheme(.dark)
}
