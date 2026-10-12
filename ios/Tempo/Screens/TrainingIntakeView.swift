import SwiftUI

/// "Start training" (#102): a tappable form, about ninety seconds, then one coach turn that
/// reflects it back and proposes the goal through the usual create_plan card.
///
/// Two ways in, one flow:
/// - **Train for something** anywhere in the app → `TabRouter.trainForSomething()`. The cover is
///   attached once, at the root (`.trainingIntake()`), so a CTA only has to flip the router.
/// - **Onboarding step 1** → `OnboardingView` embeds this with `entry: .onboarding`, which adds
///   "Just running for now" and drops the close button.
///
/// The view is declarative over `IntakeAnswers`; whether a step is complete and what the
/// answers become are decided there, and pinned in `TrainingIntakeTests`.
struct TrainingIntakeView: View {
    enum Entry { case onboarding, startTraining }

    let entry: Entry
    /// Nil when the athlete closed the form without sending it.
    let onFinish: (IntakeAnswers?) -> Void

    @State private var answers: IntakeAnswers
    @State private var step: IntakeAnswers.Step = .situation
    /// Issues are shown only after a Next tap that hit them — not while the athlete is
    /// still filling the step in.
    @State private var showIssues = false
    @State private var pickingDate = false

    init(entry: Entry, seed: IntakeAnswers = IntakeAnswers(), onFinish: @escaping (IntakeAnswers?) -> Void) {
        self.entry = entry
        self.onFinish = onFinish
        _answers = State(initialValue: seed)
    }

    private var issues: [IntakeAnswers.Issue] {
        answers.issues(on: step, today: .now, calendar: RunStore.cal)
    }

    /// "Just running" ends the flow at step 1; there is nothing else to ask.
    private var isLastStep: Bool {
        step == .notes || (step == .situation && answers.situation == .justRunning)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.xl2) {
                    switch step {
                    case .situation: situationStep
                    case .race: raceStep
                    case .plan: planStep
                    case .focus: focusStep
                    case .notes: notesStep
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            footer
        }
        .background(Tokens.Palette.canvas.ignoresSafeArea())
        .animation(Motion.reveal, value: step)
        // The answers that add or remove fields. Not `answers` whole: that would animate
        // every keystroke in the notes field.
        .animation(Motion.reveal, value: answers.situation)
        .animation(Motion.reveal, value: answers.distance)
        .animation(Motion.reveal, value: answers.goalType)
        .animation(Motion.reveal, value: answers.planStyle)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            if step != .situation {
                Button { go(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(Pressable())
                .accessibilityLabel("Back")
            }
            progressBar
            if entry == .startTraining {
                Button { onFinish(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(Pressable())
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }

    private var progressBar: some View {
        let total = IntakeAnswers.Step.allCases.count
        return HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i <= step.rawValue ? Tokens.Palette.voltMark : Tokens.Palette.elevated)
                    .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(total)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showIssues, let first = issues.first {
                Text(first.message)
                    .font(Tokens.Font.ui(13))
                    .foregroundStyle(Tokens.Palette.danger)
                    .transition(.opacity)
            }
            PrimaryButton(title: isLastStep ? (answers.situation == .justRunning ? "Continue" : "Send to coach") : "Next") {
                advance()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private func advance() {
        guard issues.isEmpty else {
            showIssues = true
            Haptics.warn()
            return
        }
        showIssues = false
        if isLastStep {
            Haptics.commit()
            onFinish(answers)
        } else {
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = IntakeAnswers.Step(rawValue: step.rawValue + delta) else { return }
        showIssues = false
        step = next
    }

    // MARK: - 1. Where are you right now?

    private var situationStep: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            heading("Where are you right now?", "So the plan starts from where you actually are.")
            option(.newBlock, "I want to train for a race", "A race on the calendar, or one you're about to sign up for.")
            option(.midBlock, "I'm training for a race now", "Already mid-block. The plan picks up from the week you're in, anchored on your real runs.")
            if entry == .onboarding {
                option(.justRunning, "Just running for now", "No race, no plan. Your coach still reads every run.")
            }
        }
    }

    private func option(_ value: IntakeAnswers.Situation, _ title: String, _ detail: String) -> some View {
        OptionRow(title: title, detail: detail, selected: answers.situation == value) {
            answers.situation = value
            // A Stepper can't step down onto its own minimum, so "week 1" has to start there.
            if value == .midBlock, answers.startedWeek == nil { answers.startedWeek = 1 }
        }
    }

    // MARK: - 2. The race

    private var raceStep: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl2) {
            heading("The race", answers.situation == .midBlock ? "The one you're training for now." : nil)

            field("Distance") {
                FlowLayout(spacing: 8) {
                    ForEach(IntakeAnswers.Distance.allCases, id: \.self) { d in
                        Chip(d.label, selected: answers.distance == d) { answers.distance = d }
                    }
                }
                if answers.distance == .custom {
                    TextField("Distance in metres", value: $answers.customMeters, format: .number)
                        .keyboardType(.numberPad)
                        .modifier(InputStyle())
                }
            }

            field("Race name") {
                TextField("Optional", text: $answers.raceName)
                    .textInputAutocapitalization(.words)
                    .modifier(InputStyle())
            }

            field("Race date") {
                Button {
                    pickingDate.toggle()
                    // Opening the calendar shows a selected day; make the answer match what's
                    // on screen rather than leave a highlighted date that isn't saved.
                    if pickingDate, answers.raceDate == nil { answers.raceDate = Self.defaultPickerDate }
                } label: {
                    HStack {
                        Text(answers.raceDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Pick a date")
                            .font(Tokens.Font.ui(15, .medium))
                            .foregroundStyle(answers.raceDate == nil ? Tokens.Palette.textTertiary : Tokens.Palette.textPrimary)
                        Spacer()
                        Image(systemName: "calendar")
                            .foregroundStyle(Tokens.Palette.textTertiary)
                    }
                    .modifier(InputStyle())
                }
                .buttonStyle(Pressable())
                if pickingDate {
                    DatePicker(
                        "Race date",
                        selection: Binding(
                            get: { answers.raceDate ?? Self.defaultPickerDate },
                            set: { answers.raceDate = $0 }
                        ),
                        in: Self.tomorrow...,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .tint(Tokens.Palette.accentText)
                }
            }

            if answers.situation == .midBlock {
                field("Where you are in the block") {
                    Stepper(value: Binding(
                        get: { answers.startedWeek ?? 1 },
                        set: { answers.startedWeek = $0 }
                    ), in: IntakeAnswers.startedWeekRange) {
                        Text("Week \(answers.startedWeek ?? 1)")
                            .font(Tokens.Font.ui(15, .medium))
                            .foregroundStyle(Tokens.Palette.textPrimary)
                    }
                    TextField("Miles in a typical week right now (optional)", value: $answers.currentWeeklyMiles, format: .number)
                        .keyboardType(.decimalPad)
                        .modifier(InputStyle())
                }
            }

            field("Course") {
                FlowLayout(spacing: 8) {
                    ForEach(IntakeAnswers.Course.allCases, id: \.self) { c in
                        Chip(c.label, selected: answers.course == c) { answers.course = c }
                    }
                }
            }

            field("Goal") {
                FlowLayout(spacing: 8) {
                    ForEach(IntakeAnswers.GoalType.allCases, id: \.self) { g in
                        Chip(g.label, selected: answers.goalType == g) { answers.goalType = g }
                    }
                }
                if answers.goalType == .time {
                    FinishTimePicker(seconds: $answers.goalTimeSeconds)
                } else {
                    hint(answers.goalType == .unsure
                         ? "Your coach will suggest a goal from your data."
                         : "Your coach will still set a pace target from your data, so the workouts have one.")
                }
            }
        }
    }

    // MARK: - 3. The plan

    private var planStep: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl2) {
            heading("The plan", nil)

            field("Do you want a plan?") {
                ForEach(IntakeAnswers.PlanStyle.allCases, id: \.self) { style in
                    OptionRow(title: style.label, detail: Self.planStyleDetail(style), selected: answers.planStyle == style) {
                        answers.planStyle = style
                    }
                }
            }

            field("Days per week") {
                HStack(spacing: 8) {
                    ForEach(3...7, id: \.self) { n in
                        Chip("\(n)", selected: answers.daysPerWeek == n, fill: true) { answers.daysPerWeek = n }
                    }
                }
            }

            field("Long-run day") {
                FlowLayout(spacing: 8) {
                    // Monday first, as the plan grid reads; stored 0 = Sunday, as the profile does.
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                        Chip(String(IntakeAnswers.weekday(day).prefix(3)), selected: answers.longRunDay == day) {
                            answers.longRunDay = day
                        }
                    }
                }
            }

            if answers.asksLongRunCount, let threshold = answers.distance.longRunThresholdMiles {
                field("Long runs of \(threshold)+ mi in the block") {
                    Stepper(value: $answers.longRunCount, in: IntakeAnswers.longRunCountRange) {
                        Text("\(answers.longRunCount)")
                            .font(Tokens.Font.display(22))
                            .foregroundStyle(Tokens.Palette.textPrimary)
                    }
                }
            }

            if answers.asksQuality {
                field("Workouts you'll actually do") {
                    FlowLayout(spacing: 8) {
                        ForEach(IntakeAnswers.Quality.allCases, id: \.self) { q in
                            Chip(q.label, selected: answers.quality.contains(q)) { answers.quality.formSymmetricDifference([q]) }
                        }
                    }
                    hint("Pick none and your coach chooses the mix.")
                }
            }

            field("Strength work") {
                Toggle(isOn: $answers.wantsStrength) {
                    Text("Prescribe strength and mobility")
                        .font(Tokens.Font.ui(15, .medium))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                }
                .tint(Tokens.Palette.voltMark)
            }

            field("Risk") {
                OptionRow(title: "Standard", detail: "Measured ramps. The conservative line.", selected: answers.risk == .standard) {
                    answers.risk = .standard
                }
                OptionRow(title: "Ambitious", detail: "Push the ramp. Your coach names the risk once, then commits.", selected: answers.risk == .ambitious) {
                    answers.risk = .ambitious
                }
            }
        }
    }

    private static func planStyleDetail(_ style: IntakeAnswers.PlanStyle) -> String {
        switch style {
        case .full: return "Every session, every day, with paces."
        case .weekly: return "Weekly mileage plus the long run and key workouts. You fill in the rest."
        case .none: return "No schedule. Your coach reads every run and keeps you pointed at race day."
        }
    }

    // MARK: - 4. Coaching focus

    /// Four headings, six keys: the last heading holds three things the coach weights
    /// separately (David, 2026-10-12).
    private static let focusGroups: [(String, [IntakeAnswers.Focus])] = [
        ("Fueling & nutrition", [.fueling]),
        ("Pacing & workouts", [.pacing]),
        ("Race-day strategy", [.raceDay]),
        ("Recovery, strength & mental game", [.recovery, .strength, .mental]),
    ]

    private var focusStep: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl2) {
            heading("What should your coach lean into?", "Pick any. These shape your check-ins and run takeaways.")
            ForEach(Self.focusGroups.indices, id: \.self) { i in
                field(Self.focusGroups[i].0) {
                    FlowLayout(spacing: 8) {
                        ForEach(Self.focusGroups[i].1, id: \.self) { f in
                            Chip(f.label, selected: answers.focus.contains(f)) { answers.focus.formSymmetricDifference([f]) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 5. Anything else

    private var notesStep: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            heading("Anything else?", "Injuries, travel, a busy month at work. Your coach reads this and follows up.")
            ZStack(alignment: .topLeading) {
                if answers.notes.isEmpty {
                    Text("e.g. Left Achilles flared up in March. Away for a wedding in week 6.")
                        .font(Tokens.Font.ui(15))
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $answers.notes)
                    .font(Tokens.Font.ui(15))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .frame(minHeight: 160)
            }
            .background(Tokens.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        }
    }

    // MARK: - Pieces

    private static var tomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    /// Where the calendar opens before a date is picked. Only a starting page — nothing is
    /// saved until the athlete taps a day.
    private static var defaultPickerDate: Date {
        Calendar.current.date(byAdding: .weekOfYear, value: 12, to: .now) ?? .now
    }

    private func heading(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).display(30)
            if let subtitle {
                Text(subtitle)
                    .font(Tokens.Font.ui(14))
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineSpacing(2)
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(label)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Font.ui(12))
            .foregroundStyle(Tokens.Palette.textTertiary)
    }
}

// MARK: - Root presentation

extension View {
    /// Attach once, at the root of the main app. Presents the intake whenever
    /// `TabRouter.trainForSomething()` is called; on send, hands the answers to the coach.
    func trainingIntake(router: TabRouter, store: RunStore) -> some View {
        fullScreenCover(isPresented: Binding(
            get: { router.trainingIntakeShown },
            set: { router.trainingIntakeShown = $0 }
        )) {
            TrainingIntakeView(
                entry: .startTraining,
                seed: IntakeAnswers(daysPerWeek: store.daysPerWeek, longRunDay: store.longRunDay, risk: store.riskTolerance)
            ) { answers in
                router.trainingIntakeShown = false
                guard let answers else { return }
                store.beginIntake(answers)
                router.showCoach()
            }
            .environmentObject(store)
            .environmentObject(router)
        }
    }
}

// MARK: - Controls

/// Selectable capsule. Volt fill when on — volt is a fill, so `onVolt` text sits on it.
private struct Chip: View {
    let title: String
    let selected: Bool
    var fill = false
    let action: () -> Void

    init(_ title: String, selected: Bool, fill: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.fill = fill
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Text(title)
                .font(Tokens.Font.ui(14, selected ? .semibold : .medium))
                .foregroundStyle(selected ? Tokens.Palette.onVolt : Tokens.Palette.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: fill ? .infinity : nil)
                .background(selected ? Tokens.Palette.volt : Tokens.Palette.surface)
                .clipShape(Capsule())
        }
        .buttonStyle(Pressable(haptic: false))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A single-choice card: title, one line of what it means, a check when chosen.
private struct OptionRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Tokens.Font.ui(16, .semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                    Text(detail)
                        .font(Tokens.Font.ui(13))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Tokens.Palette.accentText : Tokens.Palette.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Tokens.Well.accent.fill : Tokens.Well.neutral.fill)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        }
        .buttonStyle(Pressable(haptic: false))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// h / m / s wheels. Three wheels rather than a text field: "3:15" is three hours fifteen to
/// a marathoner and three minutes fifteen to a miler, and the form can't know which was meant.
private struct FinishTimePicker: View {
    @Binding var seconds: Int?

    private func part(_ get: @escaping (Int) -> Int, _ set: @escaping (inout (Int, Int, Int), Int) -> Void) -> Binding<Int> {
        Binding(
            get: { get(seconds ?? 0) },
            set: { new in
                let total = seconds ?? 0
                var hms = (total / 3600, (total % 3600) / 60, total % 60)
                set(&hms, new)
                seconds = hms.0 * 3600 + hms.1 * 60 + hms.2
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            wheel(part({ $0 / 3600 }, { $0.0 = $1 }), 0..<10, "h")
            wheel(part({ ($0 % 3600) / 60 }, { $0.1 = $1 }), 0..<60, "m")
            wheel(part({ $0 % 60 }, { $0.2 = $1 }), 0..<60, "s")
        }
        .frame(height: 140)
        .background(Tokens.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }

    private func wheel(_ value: Binding<Int>, _ range: Range<Int>, _ unit: String) -> some View {
        Picker(unit, selection: value) {
            ForEach(range, id: \.self) { n in
                Text("\(n) \(unit)").font(Tokens.Font.mono(16)).tag(n)
            }
        }
        .pickerStyle(.wheel)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

private struct InputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Tokens.Font.ui(15))
            .foregroundStyle(Tokens.Palette.textPrimary)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Tokens.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }
}

/// Left-aligned wrapping row, for chips whose labels vary in width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

#Preview {
    TrainingIntakeView(entry: .startTraining) { _ in }
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
}
