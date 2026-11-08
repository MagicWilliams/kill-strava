import SwiftUI

/// The permission screen: who gets the data, what goes, what doesn't, and a real choice.
///
/// One screen, three doors: a step in onboarding, a cover over the app for an athlete who
/// predates this and has never answered, and a sheet from `CoachConsentNotice` or the You tab.
/// Saying no is a full-size button right under the yes, on purpose. A permission that is easy
/// to give and hard to find the way out of isn't the explicit one the guideline asks for.
struct CoachConsentView: View {
    var eyebrow: String? = nil
    /// The answer just recorded, or nil when an athlete who had agreed left it as it was.
    let onDone: (CoachConsent.Decision?) -> Void

    @ObservedObject private var consent = CoachConsentStore.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading
                    section(CoachConsent.Copy.sentHeading, CoachConsent.Copy.sent, symbol: "arrow.up.right", tint: Tokens.Palette.accentText)
                    section(CoachConsent.Copy.notSentHeading, CoachConsent.Copy.notSent, symbol: "xmark", tint: Tokens.Palette.textTertiary)
                    closing
                }
                .padding(.horizontal, 28)
                .padding(.top, 32)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Visible, unlike the rest of the app: on a phone this tall the privacy policy link
            // is below the fold, and the bar is what says there is more to read before answering.
            .scrollIndicators(.visible)
            buttons
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 28)
        }
        .background(Tokens.Palette.canvas.ignoresSafeArea())
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let eyebrow {
                SectionLabel(eyebrow, color: Tokens.Palette.accentText)
            }
            Text(CoachConsent.Copy.title)
                .font(Tokens.Font.display(34))
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text(CoachConsent.Copy.lead)
                .font(Tokens.Font.ui(15))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .lineSpacing(3)
            if consent.status == .agreed {
                Text(CoachConsent.Copy.sharingOn)
                    .font(Tokens.Font.ui(14, .semibold))
                    .foregroundStyle(Tokens.Palette.success)
            }
        }
    }

    private func section(_ title: String, _ lines: [String], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(Tokens.Font.ui(14))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var closing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(CoachConsent.Copy.purpose)
            Text(CoachConsent.Copy.decline)
            Link(CoachConsent.Copy.policyLink, destination: CoachConsent.privacyPolicy)
                .font(Tokens.Font.ui(14, .semibold))
                .foregroundStyle(Tokens.Palette.accentText)
        }
        .font(Tokens.Font.ui(13))
        .foregroundStyle(Tokens.Palette.textSecondary)
        .lineSpacing(2)
    }

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 10) {
            if consent.status == .agreed {
                PrimaryButton(title: CoachConsent.Copy.keepSharing) { onDone(nil) }
                SecondaryButton(title: CoachConsent.Copy.stopSharing) { answer(.declined) }
            } else {
                PrimaryButton(title: CoachConsent.Copy.agree) { answer(.agreed) }
                SecondaryButton(title: CoachConsent.Copy.dontShare) { answer(.declined) }
            }
        }
    }

    private func answer(_ decision: CoachConsent.Decision) {
        consent.decide(decision)
        onDone(decision)
    }
}

/// What a coach surface shows in place of the coach while the gate is shut: why, and the way
/// to change it. Drop it into a `Card` or anything else; it brings no well of its own.
struct CoachConsentNotice: View {
    @ObservedObject private var consent = CoachConsentStore.shared
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(CoachConsent.Copy.offLabel, color: Tokens.Palette.accentText)
            Text(CoachConsent.Copy.notice(for: consent.status))
                .font(Tokens.Font.ui(13))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button { reviewing = true } label: {
                Text(CoachConsent.Copy.review)
                    .font(Tokens.Font.ui(13, .semibold))
                    .foregroundStyle(Tokens.Palette.accentText)
            }
            .buttonStyle(Pressable())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $reviewing) {
            CoachConsentView { _ in reviewing = false }
        }
        .task { await consent.reloadIfUnknown() }
    }
}

#Preview {
    CoachConsentView(eyebrow: "Step 2 of 4") { _ in }
}
