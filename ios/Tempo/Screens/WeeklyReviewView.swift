import SwiftUI

/// One finished week, read back (#91, mockup screen 5).
///
/// The app is good at today and at the race, and had nothing in between: no screen said what
/// a week amounted to, what moved in the plan during it, or what that means for the next one.
/// This is that screen, and it is deliberately a *record* rather than a live view — the
/// headline, the three sections and the tiles are all read off the review as it was written
/// (`WeeklyReviewService`), so what the coach said and the numbers it said it about cannot
/// drift apart afterwards.
///
/// The one thing drawn live is the 12-week chart, which is the same component Today draws
/// from the same function (`MileageProgression.progression`), window and all — the issue asks
/// for the chart to match Today's, so it is built exactly as Today builds it rather than
/// re-windowed onto the reviewed week.
struct WeeklyReviewView: View {
    let review: WeeklyReview.Written

    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @ObservedObject private var consent = CoachConsentStore.shared

    @State private var starting = false
    @State private var couldNotStart = false

    private var stats: WeeklyReview.Stats { review.stats }

    /// "Nov 9" — the week's Monday, formatted here because what a date reads as depends on
    /// the athlete's locale, which is why `WeeklyReview` takes the label rather than the date.
    private var weekLabel: String {
        review.weekOf.formatted(.dateTime.month(.abbreviated).day())
    }

    private var phase: String? {
        WeeklyReview.phaseLabel(
            weekStart: review.weekOf,
            planStart: store.plan?.startDate,
            weeks: store.planWeeks,
            raceDay: store.goal?.raceDay
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hero
                tiles
                MileageProgressionCard(progression: MileageProgression.progression(runs: store.runs))
                section("Training", review.sections.training)
                planMoved
                section("Next week", review.sections.nextWeek)
                if consent.maySend { discussButton }
                if couldNotStart {
                    Text("Couldn't start a conversation just now. Try again from Coach.")
                        .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.danger)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.canvas)
        .toolbar(.hidden, for: .navigationBar)
        // Opening it is what reads it. Fire-and-forget, and only the first open counts: see
        // `WeeklyReviewService.markRead`.
        .task { WeeklyReviewService.markRead(review.id) }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Tokens.Palette.surface, in: Circle())
            }
            SectionLabel("Weekly review", color: Tokens.Palette.accentText)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var hero: some View {
        Card(well: .accent) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(WeeklyReview.subtitle(weekLabel: weekLabel, phase: phase))
                Text(review.headline)
                    .display(21)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Miles against the plan, sessions done, form at the end of the week against its start.
    /// Each caption is absent rather than invented when there is nothing to compare against.
    private var tiles: some View {
        HStack(spacing: 10) {
            StatTile(
                value: units.number(miles: stats.miles),
                label: units.tileName,
                caption: stats.plannedMiles.map { "plan \(units.number(miles: $0, decimals: 0))" }
            )
            StatTile(
                value: WeeklyReview.sessionsLine(stats) ?? Units.missing,
                label: "Sessions",
                caption: WeeklyReview.changedLine(stats)
            )
            StatTile(
                value: WeeklyReview.formValue(stats) ?? Units.missing,
                label: "Form",
                caption: WeeklyReview.formCaption(stats)
            )
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            Text(body)
                .font(Tokens.Font.ui(15))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// The plan section, with the way into the ledger the prose is describing. "What changed"
    /// holds the entries themselves; the review says why they happened.
    private var planMoved: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("How the plan moved, and why", review.sections.planMoved)
            if let link = WeeklyReview.changesLink(stats) {
                Button { router.openChanges() } label: {
                    HStack(spacing: 6) {
                        Text(link).font(Tokens.Font.ui(13, .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Tokens.Palette.accentText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
            }
        }
    }

    private var discussButton: some View {
        PrimaryButton(
            title: starting ? "Starting\u{2026}" : "Discuss this review",
            loading: starting,
            action: discuss
        )
        .padding(.top, 8)
    }

    /// A new conversation, with the week named in the composer and nothing sent.
    ///
    /// A fresh thread rather than the live one: the review is a new subject, and the coach
    /// reads a thread's recap at the top of the next conversation, so starting one here is
    /// what lets this discussion be found again later. `startFresh` keeps the create, the
    /// write-up of the conversation being left, and the open in the order they have to happen.
    /// The sentence is prefilled and unsent, the same hand-off "Change race or date" makes
    /// (#233): the athlete reads it, edits it, or backs out.
    private func discuss() {
        guard !starting else { return }
        starting = true
        couldNotStart = false
        Task {
            defer { starting = false }
            do {
                let fresh = try await CoachThreadService.startFresh(context: store.coachContext())
                router.coachDraft = TabRouter.Draft(text: WeeklyReview.discussDraft(weekLabel: weekLabel))
                router.openCoachThread(fresh.id)
            } catch {
                Telemetry.error("coach.thread_create_failed", error)
                couldNotStart = true
            }
        }
    }
}

#Preview {
    NavigationStack {
        WeeklyReviewView(review: WeeklyReview.Written(
            id: UUID(),
            weekOf: Date(timeIntervalSince1970: 1_793_491_200),
            headline: "The taper did its job. You are carrying less fatigue than any week since July.",
            sections: WeeklyReview.Sections(
                training: "Tuesday's strides were the sharpest of the block, and the easy runs held their pace at a lower heart rate than in August.",
                planMoved: "Race week was added on Wednesday. Thursday's tempo became an easy 5 after you said the calf was tight.",
                nextWeek: "Race Sunday. Then a week with nothing structured in it: walk, sleep, and tell me how the legs feel on Wednesday."
            ),
            stats: WeeklyReview.Stats(
                miles: 22.4, runCount: 5, plannedMiles: 24,
                sessionsDone: 4, sessionsPlanned: 5, sessionsChanged: 1,
                changes: 2, formStart: -3.1, formEnd: 9.2
            ),
            readAt: nil
        ))
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
    }
    .preferredColorScheme(.dark)
}
