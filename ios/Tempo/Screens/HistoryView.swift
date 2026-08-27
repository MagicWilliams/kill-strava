import SwiftUI

/// The run archive — every run on file, not the trailing two weeks.
///
/// All 2,000+ runs are already in `RunStore.runs` (the Supabase read has no limit), so
/// this screen is pure presentation: no fetch, no spinner, no pagination. The month
/// grouping and record set come from `RunHistory`, which is pure and pinned by tests.
///
/// It owns its own `ScrollView` rather than living inside `Screen` because the archive
/// needs a `LazyVStack` with pinned month headers — 2,000 eagerly-built rows would
/// stutter, and a nested scroll view inside `Screen` would fight the outer one.
struct HistoryView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    @State private var filter: Filter = .all
    @State private var months: [RunHistory.Month] = []
    @State private var records = RunHistory.Records()
    @State private var wall: [RunHistory.YearBlock] = []

    enum Filter: String, CaseIterable, Identifiable {
        case all, tenK, half, records

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:     return "All"
            case .tenK:    return "10K+"
            case .half:    return "Half+"
            case .records: return "PRs"
            }
        }

        func matches(_ run: RunSummary, records: RunHistory.Records) -> Bool {
            switch self {
            case .all:     return true
            case .tenK:    return run.miles >= RunHistory.Band.tenK.minMiles
            case .half:    return run.miles >= RunHistory.Band.half.minMiles
            case .records: return records.recordRunIDs.contains(run.id)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Tokens.Palette.canvas.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    header
                    totals
                    wallCard
                    recordsCard
                    filterRow
                    archive
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)

            backButton
        }
        .toolbar(.hidden, for: .navigationBar)
        // rebuildArchive ends by rebuilding the months itself: SwiftUI does not order two
        // .task modifiers, and the "PRs" filter reads the record set. Left as two independent
        // tasks, a load that landed months-first would filter against an empty record set and
        // stay empty until the filter was toggled.
        .task(id: store.runs.count) { rebuildArchive() }
        .task(id: filter) { rebuildMonths() }
    }

    /// Records and the wall always describe the whole archive — a "PR" badge that came and
    /// went with the filter would be lying about the run, and a wall that emptied when you
    /// tapped "Half+" would be reporting rest days that were not rest days. Kept off the
    /// filter's task so tapping a chip doesn't recompute five years of calendar cells.
    private func rebuildArchive() {
        records = RunHistory.records(store.runs)
        wall = RunHistory.wall(store.runs)
        rebuildMonths()
    }

    private func rebuildMonths() {
        let visible = filter == .all
            ? store.runs
            : store.runs.filter { filter.matches($0, records: records) }
        months = RunHistory.byMonth(visible)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("History").font(Tokens.Font.display(28)).foregroundStyle(Tokens.Palette.textPrimary)
            Text(subtitle).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
        .padding(.top, 56)
    }

    private var subtitle: String {
        guard records.totalRuns > 0 else { return "No runs on file yet." }
        let runs = records.totalRuns.formatted()
        let miles = Int(records.totalMiles.rounded()).formatted()
        guard let first = records.firstRun else { return "\(runs) runs · \(miles) mi" }
        return "\(runs) runs · \(miles) mi since \(first.formatted(.dateTime.month(.abbreviated).year()))"
    }

    @ViewBuilder private var wallCard: some View {
        if !wall.isEmpty {
            TrainingWall(blocks: wall) { runID in
                if let run = store.runs.first(where: { $0.id == runID }) { router.openRun(run) }
            }
        }
    }

    private var totals: some View {
        HStack(spacing: 10) {
            StatTile(value: Int(records.totalMiles.rounded()).formatted(), label: "Total miles")
            StatTile(value: hours, label: "Hours run")
            StatTile(
                value: records.currentStreakDays > 0 ? "\(records.currentStreakDays)d" : "—",
                label: records.currentStreakDays > 0 ? "Streak" : "Best \(records.longestStreakDays)d"
            )
        }
    }

    private var hours: String {
        Int((Double(records.totalDurationS) / 3600).rounded()).formatted()
    }

    // MARK: - Records

    @ViewBuilder private var recordsCard: some View {
        if records.totalRuns > 0 {
            Card {
                SectionLabel("Records", color: Tokens.Palette.volt)

                if let longest = records.longestRun {
                    recordRow(
                        "Longest run",
                        value: String(format: "%.1f mi", longest.miles),
                        run: longest
                    )
                }
                ForEach(RunHistory.Band.allCases) { band in
                    if let best = records.fastestRun[band], let pace = best.paceSecPerMile {
                        recordRow(
                            "Fastest \(band.label) run",
                            value: PaceModel.format(pace) + " /mi",
                            run: best
                        )
                    }
                }
                if let week = records.biggestWeek {
                    staticRecordRow(
                        "Biggest week",
                        value: String(format: "%.1f mi", week.miles),
                        caption: "week of " + week.weekStart.formatted(.dateTime.month(.abbreviated).day())
                    )
                }
                if let month = records.biggestMonth {
                    staticRecordRow(
                        "Biggest month",
                        value: String(format: "%.0f mi", month.miles),
                        caption: month.start.formatted(.dateTime.month(.wide).year())
                    )
                }
            }
        }
    }

    /// A record that points at one run — tapping opens it.
    private func recordRow(_ label: String, value: String, run: RunSummary) -> some View {
        Button {
            router.openRun(run)
        } label: {
            HStack(spacing: 8) {
                Text(label).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                Spacer()
                Text(value).mono(13, Tokens.Palette.textPrimary)
                Text(run.start.formatted(.dateTime.month(.abbreviated).day().year()))
                    .mono(11, Tokens.Palette.textTertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10)).foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }

    /// A record spanning many runs — nothing to open.
    private func staticRecordRow(_ label: String, value: String, caption: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            Spacer()
            Text(value).mono(13, Tokens.Palette.textPrimary)
            Text(caption).mono(11, Tokens.Palette.textTertiary)
        }
        .frame(height: 26)
    }

    // MARK: - Filters

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases) { f in
                let active = f == filter
                Button {
                    filter = f
                } label: {
                    Text(f.label)
                        .font(Tokens.Font.ui(12, active ? .semibold : .medium))
                        .foregroundStyle(active ? Tokens.Palette.onVolt : Tokens.Palette.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(active ? Tokens.Palette.volt : Tokens.Palette.surface)
                        .clipShape(Capsule())
                }
                .buttonStyle(Pressable())
            }
            Spacer()
        }
    }

    // MARK: - The archive

    @ViewBuilder private var archive: some View {
        if months.isEmpty {
            Text(emptyMessage)
                .font(Tokens.Font.ui(13))
                .foregroundStyle(Tokens.Palette.textTertiary)
                .padding(.top, 8)
        } else {
            ForEach(months) { month in
                Section {
                    VStack(spacing: 0) {
                        ForEach(Array(month.runs.enumerated()), id: \.element.id) { index, run in
                            if index > 0 {
                                Rectangle().fill(Tokens.Palette.divider).frame(height: 1)
                            }
                            row(run, scale: month.maxMiles)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Tokens.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                            .strokeBorder(Tokens.Palette.elevated, lineWidth: 1)
                    )
                    .padding(.bottom, 6)
                } header: {
                    monthHeader(month)
                }
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all:     return store.phase == .loading ? "Reading Apple Health…" : "No runs on file yet."
        case .tenK:    return "No runs of 10K or longer yet."
        case .half:    return "No runs of a half marathon or longer yet."
        case .records: return "No records yet — they appear once there are runs to rank."
        }
    }

    private func monthHeader(_ month: RunHistory.Month) -> some View {
        HStack {
            Text(month.start.formatted(.dateTime.month(.wide).year()).uppercased())
                .font(Tokens.Font.mono(11)).tracking(1.2)
                .foregroundStyle(Tokens.Palette.textPrimary)
            Spacer()
            Text("\(month.runCount) · \(month.miles, specifier: "%.1f") MI")
                .font(Tokens.Font.mono(11)).tracking(1.2)
                .foregroundStyle(Tokens.Palette.textTertiary)
        }
        .padding(.vertical, 8)
        .background(Tokens.Palette.canvas)
    }

    /// One run. The bar is scaled to the month's longest run, which gives a long
    /// scroll its rhythm — you can spot the long run in a week without reading a number.
    private func row(_ run: RunSummary, scale: Double) -> some View {
        Button {
            router.openRun(run)
        } label: {
            HStack(spacing: 10) {
                Text(run.start.formatted(.dateTime.weekday(.abbreviated).day()))
                    .mono(11, Tokens.Palette.textTertiary)
                    .frame(width: 46, alignment: .leading)

                GeometryReader { geo in
                    Capsule()
                        .fill(Tokens.Palette.volt.opacity(0.7))
                        .frame(
                            width: max(4, geo.size.width * CGFloat(scale > 0 ? run.miles / scale : 0)),
                            height: 5
                        )
                        .frame(maxHeight: .infinity, alignment: .center)
                }

                if records.recordRunIDs.contains(run.id) {
                    Tag(text: "PR")
                }
                if run.corrected {
                    Tag(text: "edited", fg: Tokens.Palette.info, bg: Tokens.Palette.inset)
                }

                Text(String(format: "%.1f", run.miles))
                    .font(Tokens.Font.display(15))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: 38, alignment: .trailing)

                Text(run.paceSecPerMile.map(PaceModel.format) ?? "—")
                    .mono(12, Tokens.Palette.textSecondary)
                    .frame(width: 42, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10)).foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
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
    HistoryView()
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
        .preferredColorScheme(.dark)
}
