import SwiftUI
import Charts

// MARK: - Today's prompt

/// The card at the top of Today once race day has passed (`BlockLifecycle.Phase.racePassed`).
/// It is the only way the app asks the question — nothing closes a block on its own, so this
/// stays until the athlete taps through and closes it.
struct BlockReviewPrompt: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter

    var body: some View {
        if store.blockPhase == .racePassed, let goal = store.goal {
            Button {
                Haptics.land()
                router.openBlockReview(goal)
            } label: {
                Card(well: .accent) {
                    HStack(spacing: 14) {
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Tokens.Palette.onVolt)
                            .frame(width: 44, height: 44)
                            .background(Tokens.Palette.volt, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(goal.raceName ?? RaceCountdown.unnamedRace) is done — review your block")
                                .font(Tokens.Font.ui(17, .bold)).foregroundStyle(Tokens.Palette.textPrimary)
                                .multilineTextAlignment(.leading)
                            Text("Look back at the training, record your official time, and close it out.")
                                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Tokens.Palette.accentText)
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(Pressable())
        }
    }
}

// MARK: - Past blocks

/// Closed blocks, newest first — on You, and on Plan between blocks. Each opens its review.
/// Renders nothing when there are none, which is also what it shows before migration 0013
/// is applied (`BlockReviewService.pastBlocks` can't read the columns yet).
struct PastBlocksCard: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter

    var body: some View {
        if !store.pastBlocks.isEmpty {
            Card {
                SectionLabel("Past blocks")
                ForEach(store.pastBlocks) { block in
                    Button { router.openBlockReview(block) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(block.raceName ?? RaceCountdown.unnamedRace)
                                    .font(Tokens.Font.ui(14, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                                Text(([BlockReview.distanceLabel(block.distance)]
                                      + [block.raceDay?.formatted(.dateTime.month(.abbreviated).day().year())].compactMap { $0 })
                                    .joined(separator: " · "))
                                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
                            }
                            Spacer()
                            Text(result(block)).font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.accentText)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10)).foregroundStyle(Tokens.Palette.textTertiary)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable())
                }
            }
        }
    }

    private func result(_ block: GoalInfo) -> String {
        switch BlockCloseout.Outcome(rawValue: block.outcome ?? "") {
        case .raced?:        return block.result_time_s.map(PaceModel.formatFinish) ?? "Raced"
        case .didNotStart?:  return "DNS"
        case .didNotFinish?: return "DNF"
        case .abandoned?:    return "Ended early"
        case nil:            return ""
        }
    }
}

// MARK: - The review

/// A whole block, read back: the weeks, the numbers, the projection against the result, and
/// the coach's retrospective. Opened from Today's prompt (an open block) or from Past blocks
/// on You (a closed one). All arithmetic is in `BlockReview`; this view draws it.
struct BlockReviewView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    /// Local, because closing changes it here and now — and because once the store reloads
    /// after a close, `store.goal` is no longer this block.
    @State private var goal: GoalInfo
    @State private var planSide: BlockReviewService.PlanSide?
    @State private var loading = true
    @State private var retrospective: String?
    @State private var writingRetrospective = false
    @State private var retrospectiveFailed = false
    @State private var closing = false

    init(goal: GoalInfo) {
        _goal = State(initialValue: goal)
    }

    private var raceMeters: Double { RaceRecap.raceMeters(goalDistance: goal.distance) }
    private var raceName: String { goal.raceName.flatMap { $0.isEmpty ? nil : $0 } ?? RaceCountdown.unnamedRace }
    private var isClosed: Bool { goal.outcome != nil }

    /// The plan's start when it loaded; otherwise the sixteen weeks `RaceRecap.block` uses,
    /// so a failed plan read still shows the training rather than nothing.
    private var blockStart: Date? {
        if let start = planSide?.plan.startDate { return start }
        guard let raceDay = goal.raceDay else { return nil }
        return Calendar.current.date(byAdding: .day, value: -RaceRecap.blockWeeks * 7, to: raceDay)
    }

    private var review: BlockReview.Review? {
        guard let raceDay = goal.raceDay, let blockStart else { return nil }
        return BlockReview.review(
            runs: store.runs,
            planStart: blockStart,
            raceDay: raceDay,
            raceMeters: raceMeters,
            planWeeks: planSide?.weeks ?? [],
            sessions: planSide?.sessions ?? []
        )
    }

    /// The race as a run: the one the goal recorded, or — while the block is open — whatever
    /// `RaceRecap.isRace` finds on race day (the longest, if several qualify).
    private var raceRun: RunSummary? {
        if let id = goal.race_run_id { return store.runs.first { $0.id == id } }
        guard !isClosed else { return nil }
        return store.runs.filter { RaceRecap.isRace(run: $0, goal: goal) }.max { $0.distanceM < $1.distanceM }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hero
                if let review {
                    weeksCard(review)
                    tiles(review)
                    projectionCard(review)
                } else if !loading {
                    Card {
                        Text("This goal has no race date, so there's no block to measure.")
                            .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
                    }
                }
                if let run = raceRun { recapLink(run) }
                retrospectiveCard
                if !isClosed { closeButton }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(isPresented: $closing) {
            CloseBlockSheet(goal: goal, planID: planSide?.plan.id, raceRun: raceRun) { closed in
                closing = false
                didClose(closed)
            }
            .environmentObject(store)
        }
    }

    private func load() async {
        guard loading else { return }
        planSide = await BlockReviewService.planSide(for: goal)
        loading = false
        retrospective = goal.review?.text
        if isClosed, retrospective == nil { await writeRetrospective(context: store.coachContext()) }
    }

    private func didClose(_ closed: GoalInfo) {
        Haptics.commit()
        goal = closed
        // Captured now, before the reload below clears the plan out of the store.
        let context = store.coachContext()
        Task { await writeRetrospective(context: context) }
        Task {
            await store.loadPlan()
            await store.refresh()
        }
    }

    private func writeRetrospective(context: CoachContext) async {
        guard let review else { return }
        writingRetrospective = true
        retrospectiveFailed = false
        let text = await BlockReviewService.retrospective(goal: goal, review: review, context: context)
        writingRetrospective = false
        if let text {
            retrospective = text
            goal.review = BlockRetrospective(text: text, generated_at: nil)
            await store.refreshPastBlocks()
        } else {
            retrospectiveFailed = true
        }
    }

    // MARK: - Header + hero

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Tokens.Palette.surface, in: Circle())
            }
            SectionLabel("Block review", color: Tokens.Palette.accentText)
            Spacer()
            if loading { ProgressView().controlSize(.small).tint(Tokens.Palette.textTertiary) }
        }
        .padding(.top, 8)
    }

    private var hero: some View {
        Card(well: .accent) {
            VStack(alignment: .leading, spacing: 2) {
                Text(raceName).display(26)
                Text(heroDateLine)
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            switch BlockCloseout.Outcome(rawValue: goal.outcome ?? "") {
            case .raced?:
                Text(goal.result_time_s.map(PaceModel.formatFinish) ?? "—").display(52)
                goalLine
            case .didNotStart?:
                Text("Didn't race").display(36)
                goalLine
            case .didNotFinish?:
                Text("Didn't finish").display(36)
                goalLine
            case .abandoned?:
                Text("Block ended early").display(36)
                goalLine
            case nil:
                goalLine
                Text("Race day has passed. Look back over the block, then close it with your official time.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

    private var heroDateLine: String {
        var parts: [String] = [BlockReview.distanceLabel(goal.distance)]
        if let day = goal.raceDay { parts.append(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())) }
        if let closed = goal.completed_at {
            parts.append("closed " + closed.formatted(.dateTime.month(.abbreviated).day()))
        }
        return parts.joined(separator: " · ")
    }

    private var goalLine: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                SectionLabel("Goal")
                Text(goal.goalTimeSeconds.map(PaceModel.formatFinish) ?? GoalLine.unknownFinish)
                    .mono(15, Tokens.Palette.textSecondary)
            }
            if let delta = BlockCloseout.delta(resultS: goal.result_time_s, goalS: goal.goalTimeSeconds) {
                Tag(
                    text: RaceRecap.formatDelta(Double(delta)) + (delta <= 0 ? " under goal" : " over goal"),
                    fg: delta <= 0 ? Tokens.Palette.success : Tokens.Palette.warning,
                    bg: delta <= 0 ? Tokens.Well.success.insetFill : Tokens.Well.warning.insetFill
                )
            }
            Spacer()
        }
    }

    // MARK: - Weeks

    private func weeksCard(_ r: BlockReview.Review) -> some View {
        let top = max(r.weeks.map { max($0.actualMiles, $0.plannedMiles ?? 0) }.max() ?? 0, 10)
        let hasPlan = r.weeks.contains { $0.plannedMiles != nil }
        return Card {
            HStack {
                SectionLabel("\(r.weeks.count) weeks")
                Spacer()
                HStack(spacing: 10) {
                    legend(Tokens.Palette.voltMark, "RAN")
                    if hasPlan { legend(Tokens.Palette.textTertiary, "PLANNED") }
                }
            }
            Chart {
                ForEach(r.weeks) { w in
                    BarMark(x: .value("Week", w.index + 1), y: .value("Miles", w.actualMiles), width: .ratio(0.6))
                        .foregroundStyle(w.isRaceWeek ? Tokens.Palette.info : Tokens.Palette.voltMark)
                        .cornerRadius(3)
                }
                ForEach(r.weeks.filter { $0.plannedMiles != nil }) { w in
                    LineMark(x: .value("Week", w.index + 1), y: .value("Planned", w.plannedMiles ?? 0))
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    PointMark(x: .value("Week", w.index + 1), y: .value("Planned", w.plannedMiles ?? 0))
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .symbolSize(14)
                }
            }
            .chartYScale(domain: 0...(top * 1.1))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisValueLabel {
                        if let v = value.as(Int.self) { Text("W\(v)").font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Tokens.Palette.divider.opacity(0.5))
                    AxisValueLabel().font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
            .frame(height: 170)
            Text(planSide == nil && !loading
                 ? "Couldn't load the plan, so this is the \(RaceRecap.blockWeeks) weeks before race day without targets."
                 : "Race week in blue — its miles stop the day before the race.")
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).mono(9, Tokens.Palette.textTertiary).tracking(1)
        }
    }

    // MARK: - Tiles

    private func tiles(_ r: BlockReview.Review) -> some View {
        var t: [(String, String)] = [
            (String(format: "%.0f mi", r.totalMiles), "Total · \(r.runCount) runs"),
            (r.peakWeek.map { String(format: "%.1f mi", $0.actualMiles) } ?? "—",
             "Peak week" + (r.peakWeek.map { " · W\($0.index + 1)" } ?? "")),
            (r.longest.map { String(format: "%.1f mi", $0.miles) } ?? "—",
             "Longest" + (r.longest.map { " · " + $0.start.formatted(.dateTime.month(.abbreviated).day()) } ?? "")),
        ]
        if r.showsLongRunCount {
            t.append(("\(r.twentyPlusCount)", "Runs of 20+ mi"))
        } else {
            t.append(("\(r.quality.done)", "Quality sessions done"))
        }
        t.append((percent(r.all.fraction), "Sessions done · \(r.all.done)/\(r.all.planned)"))
        t.append((percent(r.quality.fraction), "Quality · \(r.quality.done)/\(r.quality.planned)"))
        t.append((percent(r.long.fraction), "Long runs · \(r.long.done)/\(r.long.planned)"))
        t.append((r.taper.map { String(format: "%.0f%%", $0.drop * 100) } ?? "—",
                  "Taper" + (r.taper.map { String(format: " · %.0f → %.0f mi", $0.peakMiles, $0.raceWeekMiles) } ?? "")))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(t.enumerated()), id: \.offset) { _, tile in
                StatTile(value: tile.0, label: tile.1)
            }
        }
    }

    private func percent(_ f: Double?) -> String {
        f.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    // MARK: - Projection vs result

    @ViewBuilder private func projectionCard(_ r: BlockReview.Review) -> some View {
        if r.projectedAtStartS != nil || r.projectedRaceMorningS != nil {
            Card(well: .cool) {
                SectionLabel("Projection vs result")
                HStack(spacing: 10) {
                    projectionTile(r.projectedAtStartS.map(PaceModel.formatFinish) ?? GoalLine.unknownFinish, "Block start")
                    projectionTile(r.projectedRaceMorningS.map(PaceModel.formatFinish) ?? GoalLine.unknownFinish, "Race morning")
                    projectionTile(goal.result_time_s.map(PaceModel.formatFinish) ?? "—", "Result")
                }
                if let line = projectionLine(r) {
                    Text(line).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
        }
    }

    private func projectionTile(_ value: String, _ label: String) -> some View {
        InsetWell(padding: 10) {
            Text(value).font(Tokens.Font.display(16)).foregroundStyle(Tokens.Palette.textPrimary)
                .minimumScaleFactor(0.7).lineLimit(1)
            SectionLabel(label)
        }
    }

    private func projectionLine(_ r: BlockReview.Review) -> String? {
        var parts: [String] = []
        if let change = r.projectionChangeS {
            parts.append(change <= 0
                ? "The block took \(RaceRecap.formatClock(Double(-change))) off the projection."
                : "The projection drifted \(RaceRecap.formatClock(Double(change))) slower across the block.")
        }
        if let morning = r.projectedRaceMorningS, let result = goal.result_time_s {
            let diff = result - morning
            parts.append(diff <= 0
                ? "You ran \(RaceRecap.formatClock(Double(-diff))) faster than race morning's projection."
                : "You finished \(RaceRecap.formatClock(Double(diff))) slower than race morning's projection.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Recap link

    private func recapLink(_ run: RunSummary) -> some View {
        Button { router.openRaceRecap(run) } label: {
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Race recap").font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                        Text(run.metricsLine(units)).font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Tokens.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(Pressable())
    }

    // MARK: - Retrospective

    private var retrospectiveCard: some View {
        Card {
            SectionLabel("Coach's retrospective", color: Tokens.Palette.accentText)
            if let retrospective {
                Text(retrospective)
                    .font(Tokens.Font.ui(14)).foregroundStyle(Tokens.Palette.textPrimary)
                    .lineSpacing(3)
                    .transition(.opacity)
            } else if !isClosed {
                Text("Written when you close the block — the coach reads it with your result in hand.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
            } else if writingRetrospective {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Tokens.Palette.textTertiary)
                    Text("The coach is reading the block…")
                        .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
                }
            } else if retrospectiveFailed {
                Text("Couldn't reach the coach.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
                Button {
                    Task { await writeRetrospective(context: store.coachContext()) }
                } label: {
                    Text("Try again").font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.accentText)
                }
                .buttonStyle(Pressable())
            }
        }
        .motion(Motion.reveal, value: retrospective)
    }

    private var closeButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            PrimaryButton(title: "Close this block") { closing = true }
            Text("Records your result, ends the plan, and moves this block to Past blocks on You.")
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }
}

// MARK: - Close-out sheet

/// How the race went. Typing the official time is the main path — see `BlockCloseout` for
/// why the race usually isn't a run we can read it from.
struct CloseBlockSheet: View {
    let goal: GoalInfo
    let planID: UUID?
    let raceRun: RunSummary?
    let onClosed: (GoalInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var outcome: BlockCloseout.Outcome = .raced
    @State private var timeText: String
    @State private var logAsRun = false
    @State private var startTime: Date
    @State private var saving = false
    @State private var error: String?
    @FocusState private var timeFocused: Bool

    init(goal: GoalInfo, planID: UUID?, raceRun: RunSummary?, onClosed: @escaping (GoalInfo) -> Void) {
        self.goal = goal
        self.planID = planID
        self.raceRun = raceRun
        self.onClosed = onClosed
        // A watch clock, as a starting point to correct — not as the answer.
        _timeText = State(initialValue: raceRun.map { PaceModel.formatFinish($0.elapsedS ?? $0.durationS) } ?? "")
        let morning = goal.raceDay.flatMap { Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: $0) }
        _startTime = State(initialValue: morning ?? .now)
    }

    private var raceMeters: Double { RaceRecap.raceMeters(goalDistance: goal.distance) }
    private var parsed: Int? { BlockCloseout.parseFinish(timeText, raceMeters: raceMeters) }
    private var canSave: Bool { outcome != .raced || parsed != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("How did \(goal.raceName ?? "the race") go?").display(24)
                    Picker("Outcome", selection: $outcome) {
                        Text("Finished").tag(BlockCloseout.Outcome.raced)
                        Text("Didn't start").tag(BlockCloseout.Outcome.didNotStart)
                        Text("Didn't finish").tag(BlockCloseout.Outcome.didNotFinish)
                    }
                    .pickerStyle(.segmented)

                    if outcome == .raced { timeEntry }

                    if let error {
                        Text(error).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.danger)
                    }

                    PrimaryButton(title: "Close the block", loading: saving) { Task { await save() } }
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.5)
                    Text("You can still review it any time from You → Past blocks.")
                        .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
                }
                .padding(20)
            }
            .background(Tokens.Palette.canvas)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(saving)
        .onAppear { if raceRun == nil { timeFocused = true } }
    }

    @ViewBuilder private var timeEntry: some View {
        Card {
            SectionLabel("Official finish time", color: Tokens.Palette.accentText)
            TextField("3:28:15", text: $timeText)
                .font(Tokens.Font.display(34))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($timeFocused)
            if let s = parsed {
                let pace = Int((Double(s) / (raceMeters / RaceRecap.metersPerMile)).rounded())
                Text("\(PaceModel.formatFinish(s)) · \(PaceModel.format(pace)) /mi")
                    .mono(12, Tokens.Palette.textSecondary)
            } else if !timeText.isEmpty {
                Text("Type it as h:mm:ss — e.g. 3:28:15.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.warning)
            }
            if let raceRun {
                Text("Pre-filled from your race-day run (\(raceRun.metricsLine(units))) — that's the watch clock. Swap in the chip time if it differs.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
            } else {
                Text("No race run in your history — enter the time from the results page.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
        if raceRun == nil {
            Card {
                Toggle(isOn: $logAsRun) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also log it as a run")
                            .font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                        Text(String(format: "%.1f mi at the finish time, so it counts in your history and totals.",
                                    raceMeters / RaceRecap.metersPerMile))
                            .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                    }
                }
                .tint(Tokens.Palette.voltMark)
                if logAsRun {
                    DatePicker("Start time", selection: $startTime, displayedComponents: .hourAndMinute)
                        .font(Tokens.Font.ui(14))
                }
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        let req = BlockReviewService.CloseRequest(
            goal: goal,
            planID: planID,
            outcome: outcome,
            finishS: outcome == .raced ? parsed : nil,
            raceRunID: raceRun?.id,
            logRunStart: (outcome == .raced && raceRun == nil && logAsRun) ? startTime : nil
        )
        do {
            let closed = try await BlockReviewService.close(req)
            onClosed(closed)
        } catch {
            self.error = error.localizedDescription
            Haptics.warn()
        }
    }
}
