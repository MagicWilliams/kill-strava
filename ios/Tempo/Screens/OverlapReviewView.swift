import SwiftUI

/// Overlapping runs, one pair at a time (#30).
///
/// Two live runs whose clocks overlap, side by side, and the athlete says which one is the
/// record — or that both are. Nothing is preselected and nothing is highlighted as the
/// "likely" answer: on 2023-11-19 every plausible rule picks the watch-left-running blob over
/// the actual marathon, and a highlighted guess is a rule wearing a UI.
///
/// The queue itself is `RunStore.overlaps`, computed by `RunDedupe.unresolvedOverlaps`; this
/// screen only lays it out and forwards taps.
struct OverlapReviewView: View {
    @EnvironmentObject private var store: RunStore
    @Environment(\.dismiss) private var dismiss

    @State private var working = false
    @State private var failed = false
    /// Count when the screen opened, for "3 of 108" — the queue shrinks as you go.
    @State private var startCount = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Tokens.Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let pair = store.overlaps.first {
                        pairCard(pair)
                        actions(pair)
                    } else {
                        doneCard
                    }
                    if failed {
                        Text("That didn't save — nothing was changed. Try again.")
                            .font(Tokens.Font.ui(12))
                            .foregroundStyle(Tokens.Palette.danger)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)

            backButton
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if startCount == 0 { startCount = store.overlaps.count } }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Overlapping runs").display(28)
                Spacer()
                if store.lastOverlapDecision != nil {
                    Button { Task { await undo() } } label: {
                        Text("Undo")
                            .font(Tokens.Font.ui(13, .semibold))
                            .foregroundStyle(Tokens.Palette.accentText)
                    }
                    .buttonStyle(Pressable())
                    .disabled(working)
                }
            }
            Text(subtitle).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
        .padding(.top, 56)
    }

    private var subtitle: String {
        let left = store.overlaps.count
        guard left > 0 else { return "Nothing left to review." }
        let total = max(startCount, left)
        return "\(total - left + 1) of \(total) · these two runs overlap in time. Which is the record?"
    }

    // MARK: - The pair

    private func pairCard(_ pair: RunDedupe.OverlapPair) -> some View {
        Card {
            SectionLabel(
                pair.earlier.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()),
                color: Tokens.Palette.accentText
            )
            HStack(alignment: .top, spacing: 10) {
                column("Left", pair.earlier)
                column("Right", pair.later)
            }
        }
    }

    private func column(_ side: String, _ run: RunSummary) -> some View {
        InsetWell {
            SectionLabel(side)
            Text(String(format: "%.2f mi", run.miles)).display(20)
            stat("Start", run.start.formatted(date: .omitted, time: .shortened))
            stat("Moving", BestEfforts.formatTime(run.durationS))
            stat("Elapsed", run.elapsedS.map(BestEfforts.formatTime) ?? "—")
            stat("Pace", run.paceSecPerMile.map { PaceModel.format($0) + " /mi" } ?? "—")
            stat("Avg HR", run.avgHR.map { "\($0) bpm" } ?? "—")
            stat("Source", run.source)
            if run.corrected {
                Tag(text: "edited", fg: Tokens.Palette.info, bg: Tokens.Palette.surface)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
            Spacer(minLength: 4)
            Text(value).mono(12, Tokens.Palette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // MARK: - Actions

    private func actions(_ pair: RunDedupe.OverlapPair) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                choice("Keep left") { await decide(pair, .keep(pair.earlier.id)) }
                choice("Keep right") { await decide(pair, .keep(pair.later.id)) }
            }
            choice("Both are real") { await decide(pair, .bothReal) }
            Text("Keeping one retires the other — it stops counting toward totals and records, but is never deleted.")
                .font(Tokens.Font.ui(11))
                .foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    private func choice(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title)
                .font(Tokens.Font.ui(15, .semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Tokens.Well.neutral.fill)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        }
        .buttonStyle(Pressable())
        .disabled(working)
        .opacity(working ? 0.6 : 1)
    }

    private var doneCard: some View {
        Card(well: .success) {
            SectionLabel("All clear", color: Tokens.Palette.success)
            Text("Every overlapping pair has been reviewed. Totals and records now count each run once.")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private func decide(_ pair: RunDedupe.OverlapPair, _ verdict: RunDedupe.OverlapVerdict) async {
        working = true
        failed = !(await store.resolveOverlap(pair, verdict))
        working = false
        if !failed { Haptics.tap() }
    }

    private func undo() async {
        working = true
        failed = !(await store.undoLastOverlapDecision())
        working = false
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

#Preview {
    OverlapReviewView()
        .environmentObject(RunStore())
        .preferredColorScheme(.dark)
}
