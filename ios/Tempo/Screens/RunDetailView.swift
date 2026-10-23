import SwiftUI
import Charts
import MapKit
import Supabase
import UIKit

/// Per-run deep dive: pace-colored route map, the coach's cached read, Garmin-style
/// stats, scrubbable pace+HR chart, time-in-zone, elevation, and mile splits.
/// Spec: progress.md → "Run Detail spec".
///
/// And the journal (#124): his photo as the hero, his title as the heading, effort and
/// shoes as tiles, feel and notes — all editable after the fact. What shows and what an
/// edit writes is `RunDetailJournal`.
struct RunDetailView: View {
    let run: RunSummary

    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @StateObject private var model = RunDetailStore()
    @StateObject private var shoes = ShoeStore()
    @State private var showFullMap = false
    @State private var editingJournal = false
    @State private var scrub: RunDetail.SeriesPoint?

    /// The journal as the store holds it now, so an edit shows the moment it lands. `run` is
    /// the copy the page was opened with.
    private var journal: RunJournalEntry {
        store.runs.first(where: { $0.id == run.id })?.journal ?? run.journal
    }

    private var photoKey: String? {
        RunDetailJournal.photoObjectKey(journal.photoPath, userID: Supa.userID)
    }

    /// Only a run with a row, on a database with the journal columns: a run shown from the
    /// offline HealthKit copy has no row to write to.
    private var canEditJournal: Bool { store.journalAvailable && model.rowExists }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    VStack(alignment: .leading, spacing: 16) {
                        titleRow
                        raceRecapCard
                        heroStats
                        journalCard
                        coachRead
                        timeAccounting
                        statsGrid
                        if let detail = model.detail, !detail.series.isEmpty {
                            paceHRChart(detail)
                        }
                        if let detail = model.detail, detail.zoneSeconds.reduce(0, +) > 60 {
                            zonesCard(detail)
                        }
                        if let detail = model.detail, detail.series.contains(where: { $0.elevationM != nil }) {
                            elevationCard(detail)
                        }
                        if let detail = model.detail, detail.splits(units).count > 1 {
                            splitsCard(detail)
                        }
                        bestEffortsCard
                        if run.corrected, let note = model.correctionNote {
                            editedStrip(note)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 40)
                    .background(Tokens.Palette.canvas)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                    .offset(y: -22)
                    .padding(.bottom, -22)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)

            backButton
        }
        .background(Tokens.Palette.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load(run: run, runStore: store) }
        .task { await shoes.load() }
        .task(id: photoKey) { await model.loadPhoto(key: photoKey) }
        .fullScreenCover(isPresented: $showFullMap) { fullMap }
        .sheet(isPresented: $editingJournal) {
            RunJournalEditSheet(runID: run.id, journal: journal, fallbackHeading: dateHeading,
                                initialPhoto: model.photo, shoes: shoes) { landed, image in
                model.adoptPhoto(image, key: RunDetailJournal.photoObjectKey(landed.photoPath, userID: Supa.userID))
                store.applyJournal(landed, toRun: run.id)
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder private var hero: some View {
        let hero = RunDetailJournal.hero(hasPhoto: photoKey != nil, photoFailed: model.photoFailed,
                                         hasRoute: model.detail?.hasRoute == true)
        if case .photo(let routeButton) = hero {
            photoHero(routeButton: routeButton)
        } else if let detail = model.detail, detail.hasRoute {
            routeMap(detail, interactive: false)
                .frame(height: 280)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.down.left.and.arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(12)
                }
                .contentShape(Rectangle())
                .onTapGesture { showFullMap = true }
        } else {
            ZStack {
                Tokens.Palette.inset
                VStack(spacing: 7) {
                    Image(systemName: model.loading ? "map" : "figure.run")
                        .font(.system(size: 22))
                        .foregroundStyle(Tokens.Palette.textTertiary)
                    Text(bannerLabel)
                        .font(Tokens.Font.mono(12))
                        .tracking(1.2)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                    if let caption = bannerCaption {
                        Text(caption)
                            .font(Tokens.Font.ui(11))
                            .foregroundStyle(Tokens.Palette.textTertiary.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 44)
                    }
                }
                .padding(.top, 24)   // clear the status bar under the sheet overlap
            }
            .frame(height: 190)
        }
    }

    /// His photo in the map's place. The route is one tap away on it, into the same full
    /// map the route hero opens.
    private func photoHero(routeButton: Bool) -> some View {
        ZStack {
            Tokens.Palette.inset
            if let photo = model.photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                ProgressView().tint(Tokens.Palette.textTertiary)
            }
        }
        .frame(height: 340)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityLabel("Run photo")
        .overlay(alignment: .bottomTrailing) {
            if routeButton {
                Button { showFullMap = true } label: {
                    Label("Route", systemImage: "map")
                        .font(Tokens.Font.ui(13, .semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(Pressable())
                .padding(.trailing, 16)
                .padding(.bottom, 34)   // clear the content sheet's 22 pt overlap
                .accessibilityLabel("Show route map")
            }
        }
    }

    private var bannerLabel: String {
        if model.loading { return "Loading route…" }
        if run.source == "manual" { return "Logged manually" }
        if model.detail?.isIndoor == true { return "Indoor run" }
        return "No route data"
    }

    private var bannerCaption: String? {
        guard !model.loading, bannerLabel == "No route data" else { return nil }
        let source = model.detail?.sourceName ?? ""
        if source.localizedCaseInsensitiveContains("garmin") || source.localizedCaseInsensitiveContains("connect") {
            return "Garmin didn't write a GPS route to Apple Health for this run. Stats and charts still cover the full run."
        }
        return "No GPS route found in Apple Health for this workout."
    }

    private func routeMap(_ detail: RunDetail, interactive: Bool) -> some View {
        RunRouteMap(detail: detail, interactive: interactive)
    }

    private var fullMap: some View {
        ZStack(alignment: .topTrailing) {
            if let detail = model.detail {
                routeMap(detail, interactive: true).ignoresSafeArea()
            }
            Button { showFullMap = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(20)
        }
        // Follows system appearance, like the hero map it expands from: tapping a light
        // hero shouldn't flip the route to a dark map. The close button stays legible
        // because its token and material adapt together.
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

    // MARK: - Title + coach read

    private var dateHeading: String {
        run.start.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// His title when he gave one, else the date. With a title, the date moves down a line
    /// beside the time, so the page still says when.
    private var titleRow: some View {
        let title = RunDetailJournal.heading(journal.title)
        let time = run.start.formatted(date: .omitted, time: .shortened)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title ?? dateHeading)
                    .font(Tokens.Font.display(24)).foregroundStyle(Tokens.Palette.textPrimary)
                if run.corrected {
                    Tag(text: "edited", fg: Tokens.Palette.info, bg: Tokens.Palette.inset)
                }
            }
            Text((title == nil ? time : dateHeading + " · " + time) + (run.source == "manual" ? " · logged manually" : ""))
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
        .padding(.top, 14)
    }

    // MARK: - Journal

    /// Effort and shoes as tiles, then feel and notes, with Edit. A run with nothing logged
    /// gets a single "add" row instead of an empty card — and nothing at all when it can't be
    /// edited, which is every run on the offline copy.
    @ViewBuilder private var journalCard: some View {
        let entry = journal
        if RunDetailJournal.hasContent(entry, shoes: shoes.shoes) {
            let tiles = RunDetailJournal.tiles(entry, shoes: shoes.shoes)
            let feel = RunDetailJournal.feelLabels(entry)
            Card {
                HStack {
                    SectionLabel("Your notes")
                    Spacer()
                    if canEditJournal {
                        Button("Edit") { editingJournal = true }
                            .font(Tokens.Font.ui(13, .semibold))
                            .foregroundStyle(Tokens.Palette.accentText)
                            .buttonStyle(.plain)
                    }
                }
                if !tiles.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(tiles, id: \.label) { tile in
                            StatTile(value: tile.value, label: tile.label)
                        }
                    }
                }
                if !feel.isEmpty {
                    FlowLayout(spacing: Tokens.Space.sm) {
                        ForEach(feel, id: \.self) { label in
                            Tag(text: label, fg: Tokens.Palette.textPrimary, bg: Tokens.Palette.inset)
                        }
                    }
                }
                if let notes = RunDetailJournal.notes(entry) {
                    Text(notes)
                        .font(Tokens.Font.ui(14)).foregroundStyle(Tokens.Palette.textPrimary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
        } else if canEditJournal {
            Button { editingJournal = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.accentText)
                    Text(photoKey == nil ? "Add effort, notes or a photo" : "Add effort or notes")
                        .font(Tokens.Font.ui(14, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
                .padding(16)
                .background(Tokens.Well.neutral.fill)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            }
            .buttonStyle(Pressable())
        }
    }

    /// The door to the race recap. Only on the run that *is* the goal race — see
    /// `RunStore.raceGoal(for:)`: the linked race run, else `RaceRecap.isRace` — so every other
    /// run's page is exactly what it was.
    @ViewBuilder private var raceRecapCard: some View {
        if let raceGoal = store.raceGoal(for: run) {
            Button { router.openRaceRecap(run) } label: {
                Card(well: .accent) {
                    HStack(spacing: 14) {
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Tokens.Palette.onVolt)
                            .frame(width: 44, height: 44)
                            .background(Tokens.Palette.volt, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Race recap")
                                .font(Tokens.Font.ui(17, .bold)).foregroundStyle(Tokens.Palette.textPrimary)
                            Text("\(raceGoal.raceName ?? RaceCountdown.unnamedRace) — every mat, both halves, where it turned")
                                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Tokens.Palette.accentText)
                    }
                }
            }
            .buttonStyle(Pressable())
        }
    }

    private var coachRead: some View {
        Card(glow: true) {
            CoachReadHeaderRow(loading: model.takeawayLoading)
            if let takeaway = model.takeaway {
                Text(takeaway)
                    .font(Tokens.Font.ui(14)).foregroundStyle(Tokens.Palette.textPrimary)
                    .lineSpacing(3)
            } else if !model.takeawayLoading {
                Text("Couldn't reach the coach — the read appears next time you open this run.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
            }
            Button {
                router.showCoach()
            } label: {
                Text("Discuss with Coach")
                    .font(Tokens.Font.ui(13, .semibold))
                    .foregroundStyle(Tokens.Palette.accentText)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Best efforts

    /// The fastest segment of each standard distance *inside this run* (#25), badged where
    /// the run holds the all-time best.
    ///
    /// Read from `run_efforts` rather than recomputed here: the archive scan already paid
    /// for the HealthKit read, and recomputing would make this page disagree with the PR
    /// table on History the moment the two scans used different sample sets.
    @ViewBuilder private var bestEffortsCard: some View {
        if !model.efforts.isEmpty {
            let holds = Set(store.bestEfforts.recordDistances(for: run.id))
            Card {
                SectionLabel("Best efforts in this run")
                ForEach(model.efforts, id: \.distanceM) { effort in
                    HStack(spacing: 8) {
                        Text(BestEfforts.distance(forKey: effort.distanceM)?.label ?? "—")
                            .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                        if holds.contains(effort.distanceM) {
                            Tag(text: "PR")
                        }
                        Spacer()
                        Text(BestEfforts.formatTime(effort.durationS)).mono(13, Tokens.Palette.textPrimary)
                        Text(BestEfforts.distance(forKey: effort.distanceM)
                            .flatMap { units.pace(seconds: Double(effort.durationS), meters: $0.meters) }
                            .map { units.formatPace($0) } ?? "—")
                            .mono(11, Tokens.Palette.textTertiary)
                            .frame(width: 58, alignment: .trailing)
                    }
                    .frame(height: 26)
                }
            }
        }
    }

    // MARK: - Stats

    /// Big distance number + the two facts you check first. Corrected DB totals win.
    ///
    /// The headline time is **moving time**, always, and it is read off the stored run
    /// rather than off HealthKit. Those used to be the same number; since migration 0009
    /// they are not necessarily — a run whose two clocks arrived as two records now has
    /// its moving clock in `duration_s`, and HealthKit's copy may be the elapsed one.
    /// Preferring the workout here would put a slow pace under a fast run.
    private var heroStats: some View {
        let d = model.detail
        let corrected = run.corrected
        let meters = corrected ? Double(run.distanceM) : (d.map { $0.miles * Units.metersPerMile } ?? Double(run.distanceM))
        let time = run.durationS
        // Derived from the two numbers beside it rather than read off HealthKit, so the
        // three cannot disagree on screen — distance ÷ time must equal the pace printed
        // between them.
        let pace = units.runPace(movingSeconds: time, meters: meters)
        return RunDistanceHeroRow(distance: units.number(meters: meters, decimals: 2),
                                  unit: units.abbreviation.uppercased(),
                                  pace: pace.map { units.formatPace($0) },
                                  time: format(seconds: time))
            .padding(.top, -4)
    }

    // MARK: - The two clocks

    /// Moving time, elapsed time, and the gap between them.
    ///
    /// Every run has two honest answers to "how long did that take", and until now the app
    /// picked one without saying which. They only differ when the athlete stopped — a light,
    /// a water fountain, a conversation — and that difference is worth seeing: a long run
    /// with twelve minutes of standing around is a different session from the same distance
    /// run straight through, even though both report the same moving pace.
    ///
    /// Moving time is the default everywhere else in the app. This is the one place that
    /// says so out loud, and the only place elapsed time is shown.
    @ViewBuilder
    private var timeAccounting: some View {
        // The stored run is the record. HealthKit's wall clock only stands in for rows the
        // backfill hasn't reached, and never for a corrected run — there the athlete's
        // numbers are the truth and HealthKit describes a run that no longer matches.
        let fallback = run.corrected ? nil : model.detail?.elapsedS
        let elapsed = run.elapsedS ?? fallback
        let clocks = TimeAccounting.resolve(movingS: run.durationS, elapsedS: elapsed)

        if elapsed != nil {
            Card {
                SectionLabel("Time")
                if clocks.hasMeaningfulStop {
                    HStack(alignment: .top, spacing: 12) {
                        clockColumn("MOVING", clocks.movingS, pace: true)
                        clockColumn("ELAPSED", clocks.elapsedS, pace: true)
                        clockColumn("STOPPED", clocks.stoppedS, pace: false)
                    }
                    Text("Pace, mileage, and this run's label all use moving time.")
                        .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
                } else {
                    Text("Ran continuously — moving and elapsed time are the same.")
                        .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
        }
    }

    private func clockColumn(_ label: String, _ seconds: Int, pace showPace: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(format(seconds: seconds)).display(20)
            SectionLabel(label)
            if showPace, let p = units.runPace(movingSeconds: seconds, meters: run.distanceM) {
                Text(units.formatPace(p))
                    .mono(11, Tokens.Palette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statsGrid: some View {
        let d = model.detail
        // A corrected run's DB totals are the truth — raw HealthKit only covers the
        // recorded portion, so its time-accounting tiles are hidden to avoid contradiction.
        let corrected = run.corrected
        // Time accounting moved out of this grid and into `timeAccounting`, which reads the
        // stored clocks rather than re-deriving them from samples. Three tiles used to show
        // moving/elapsed/elapsed-pace here from a second, sample-derived estimate; keeping
        // both meant the page could print two different answers for the same question.
        let stats: [(String, String)?] = [
            d?.bestPaceSec.map { ("BEST PACE", units.formatPace(secondsPerMile: $0)) },
            corrected ? nil : d?.avgSpeedMph.map { ("AVG SPEED", units.formatSpeed(milesPerHour: $0)) },
            (run.avgHR ?? d?.avgHR).map { ("AVG HR", "\($0) bpm") },
            d?.maxHR.map { ("MAX HR", "\($0) bpm") },
            d?.elevGainM.map { ("ELEV GAIN", units.formatElevation(meters: $0)) },
            d?.cadenceSPM.map { ("CADENCE", "\($0) spm") },
            d?.calories.map { ("CALORIES", "\($0)") },
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(stats.compactMap { $0 }.enumerated()), id: \.offset) { _, stat in
                StatTile(value: stat.1, label: stat.0)
            }
        }
    }

    private func format(seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Pace + HR chart (scrubbable)

    private func paceHRChart(_ detail: RunDetail) -> some View {
        Card {
            PaceHRHeaderRow()
            scrubReadout(detail)
            Chart {
                ForEach(detail.series) { p in
                    if let pace = p.paceSecPerMile {
                        LineMark(
                            x: .value("Distance", units.distance(miles: p.miles)),
                            y: .value("Pace", normalizedPace(pace, detail)),
                            series: .value("Series", "pace")
                        )
                        .foregroundStyle(Tokens.Palette.accentText)
                        .interpolationMethod(.catmullRom)
                    }
                }
                ForEach(detail.series) { p in
                    if let hr = p.hr {
                        LineMark(
                            x: .value("Distance", units.distance(miles: p.miles)),
                            y: .value("HR", normalizedHR(hr, detail)),
                            series: .value("Series", "hr")
                        )
                        .foregroundStyle(Tokens.Zone.z5.opacity(0.85))
                        .interpolationMethod(.catmullRom)
                    }
                }
                if let scrub {
                    RuleMark(x: .value("Distance", units.distance(miles: scrub.miles)))
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...1)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel().font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                    AxisGridLine().foregroundStyle(Tokens.Palette.divider.opacity(0.5))
                }
            }
            .frame(height: 150)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard let plot = proxy.plotFrame else { return }
                                    let x = value.location.x - geo[plot].origin.x
                                    // The axis is in the athlete's unit, so the finger is too.
                                    if let at: Double = proxy.value(atX: x) {
                                        let miles = at * units.meters / Units.metersPerMile
                                        scrub = detail.series.min(by: { abs($0.miles - miles) < abs($1.miles - miles) })
                                    }
                                }
                                .onEnded { _ in scrub = nil }
                        )
                }
            }
        }
    }

    @ViewBuilder private func scrubReadout(_ detail: RunDetail) -> some View {
        let mile = scrub.map { units.abbreviation.uppercased() + " " + units.number(miles: $0.miles, decimals: 2) } ?? "FULL RUN"
        let pace = scrub?.paceSecPerMile.map { units.formatPace(secondsPerMile: $0) }
            ?? detail.avgPaceSec.map { units.formatPace(secondsPerMile: $0) + " avg" }
        let hr = scrub?.hr.map { "\(Int($0)) bpm" } ?? detail.avgHR.map { "\($0) bpm avg" }
        let elev = scrub?.elevationM.map { units.formatElevation(meters: $0) }
        HStack(spacing: 12) {
            Text(mile).mono(11, Tokens.Palette.accentText)
            if let pace { Text(pace).mono(11, Tokens.Palette.textPrimary) }
            if let hr { Text(hr).mono(11, Tokens.Zone.z5) }
            if let elev { Text(elev).mono(11, Tokens.Palette.textSecondary) }
            Spacer()
        }
    }

    private func normalizedPace(_ pace: Double, _ detail: RunDetail) -> Double {
        let b = detail.paceBounds
        let clamped = min(max(pace, b.lowerBound), b.upperBound)
        // Faster (lower sec/mi) plots higher.
        return 1 - (clamped - b.lowerBound) / max(b.upperBound - b.lowerBound, 1)
    }

    private func normalizedHR(_ hr: Double, _ detail: RunDetail) -> Double {
        let b = detail.hrBounds
        return (min(max(hr, b.lowerBound), b.upperBound) - b.lowerBound) / max(b.upperBound - b.lowerBound, 1)
    }

    // MARK: - Zones

    private func zonesCard(_ detail: RunDetail) -> some View {
        let total = detail.zoneSeconds.reduce(0, +)
        let top = detail.zoneSeconds.max() ?? 1
        return Card {
            ZoneHeaderRow(maxHR: store.effectiveMaxHR, measured: store.maxHRIsMeasured)
            ForEach((0..<5).reversed(), id: \.self) { z in
                let secs = detail.zoneSeconds[z]
                HStack(spacing: 12) {
                    Text("Z\(z + 1)").mono(12, Tokens.Zone.all[z]).frame(width: 26, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tokens.Palette.inset)
                            Capsule().fill(Tokens.Zone.all[z])
                                .frame(width: max(4, geo.size.width * CGFloat(secs / max(top, 1))))
                        }
                    }
                    .frame(height: 12)
                    Text(zoneTime(secs) + " · " + String(format: "%.0f%%", secs / max(total, 1) * 100))
                        .mono(11, Tokens.Palette.textSecondary)
                        .frame(width: 92, alignment: .trailing)
                }
                .frame(height: 22)
            }
        }
    }

    private func zoneTime(_ secs: Double) -> String {
        let m = Int(secs) / 60, s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Elevation

    private func elevationCard(_ detail: RunDetail) -> some View {
        let summary: String? = {
            guard let gain = detail.elevGainM, let loss = detail.elevLossM else { return nil }
            return "↑ \(units.formatElevation(meters: gain)) · ↓ \(units.formatElevation(meters: loss))".uppercased()
        }()
        return Card {
            ElevationHeaderRow(summary: summary)
            Chart {
                ForEach(detail.series) { p in
                    if let elev = p.elevationM {
                        AreaMark(x: .value("Distance", units.distance(miles: p.miles)), y: .value("Elev", units.elevation(meters: elev)))
                            .foregroundStyle(
                                LinearGradient(colors: [Tokens.Palette.voltMark.opacity(0.35), Tokens.Palette.voltMark.opacity(0.02)],
                                               startPoint: .top, endPoint: .bottom)
                            )
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Distance", units.distance(miles: p.miles)), y: .value("Elev", units.elevation(meters: elev)))
                            .foregroundStyle(Tokens.Palette.accentText.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel().font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel().font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                    AxisGridLine().foregroundStyle(Tokens.Palette.divider.opacity(0.5))
                }
            }
            .frame(height: 90)
        }
    }

    // MARK: - Splits

    private func splitsCard(_ detail: RunDetail) -> some View {
        let splits = detail.splits(units)
        let fastest = splits.map(\.paceSec).min() ?? 1
        return Card {
            SectionLabel("Splits")
            HStack {
                Text(units.abbreviation.uppercased()).mono(10, Tokens.Palette.textTertiary).frame(width: 26, alignment: .leading)
                Text("PACE").mono(10, Tokens.Palette.textTertiary).frame(width: 48, alignment: .leading)
                Spacer()
                Text("HR").mono(10, Tokens.Palette.textTertiary).frame(width: 36, alignment: .trailing)
                Text("ELEV").mono(10, Tokens.Palette.textTertiary).frame(width: 44, alignment: .trailing)
            }
            ForEach(splits) { split in
                HStack {
                    Text(split.length < 0.99 ? String(format: "%.1f", split.length) : "\(split.id)")
                        .mono(12, Tokens.Palette.textSecondary).frame(width: 26, alignment: .leading)
                    Text(PaceModel.format(split.paceSec))
                        .mono(12, Tokens.Palette.textPrimary).frame(width: 48, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Tokens.Palette.voltMark.opacity(0.75))
                            .frame(width: max(6, geo.size.width * CGFloat(Double(fastest) / Double(split.paceSec))), height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    Text(split.avgHR.map { "\($0)" } ?? "–")
                        .mono(12, Tokens.Palette.textSecondary).frame(width: 36, alignment: .trailing)
                    Text(split.elevDeltaM.map { String(format: "%+.0f", units.elevation(meters: $0)) } ?? "–")
                        .mono(12, Tokens.Palette.textTertiary).frame(width: 44, alignment: .trailing)
                }
                .frame(height: 24)
            }
        }
    }

    private func editedStrip(_ note: String) -> some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.Palette.info)
                Text(note)
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }
}

// MARK: - Rows the offer probe pins (#81)

/// The rows below were lifted out of the page above so `DetailLayoutTests` can offer each one
/// every width a phone can hand it and check what it reports back.
///
/// A bare `HStack { label; Spacer(); trailing }` hands back the sum of its parts, and text
/// widths are thirds of a point, so the float sum can land a hair past the offer. The page
/// column then takes its widest child, the text-only cards round that hair up to a whole
/// device pixel, and the scroll content comes out wider than the screen — which is enough for
/// the whole page to drag sideways with nothing visibly off-screen (#74). Whether a row drifts
/// depends on its exact text widths and the width it's offered, so the shape alone proves
/// nothing: only a row the probe caught drifting carries the `.frame` fix.

struct CoachReadHeaderRow: View {
    let loading: Bool

    var body: some View {
        HStack {
            SectionLabel("Coach's read", color: Tokens.Palette.accentText)
            Spacer()
            if loading {
                ProgressView().controlSize(.small).tint(Tokens.Palette.textTertiary)
            }
        }
    }
}

/// Distance, unit, and the pace/time stack on the right. Given already-formatted strings:
/// the card derives pace from the two numbers beside it, and that arithmetic stays there.
struct RunDistanceHeroRow: View {
    let distance: String
    let unit: String
    let pace: String?
    let time: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(distance)
                .font(Tokens.Font.display(52)).foregroundStyle(Tokens.Palette.textPrimary)
            Text(unit).font(Tokens.Font.mono(14)).tracking(1.5).foregroundStyle(Tokens.Palette.textTertiary)
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                if let pace {
                    Text(pace).mono(16)
                }
                Text(time).mono(14, Tokens.Palette.textSecondary)
            }
        }
    }
}

struct PaceHRHeaderRow: View {
    var body: some View {
        HStack {
            SectionLabel("Pace + Heart rate")
            Spacer()
            LegendDot(color: Tokens.Palette.accentText, label: "PACE")
            LegendDot(color: Tokens.Zone.z5, label: "HR")
        }
    }
}

struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Tokens.Font.mono(9)).tracking(1).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }
}

struct ZoneHeaderRow: View {
    let maxHR: Int
    /// Measured from the archive, or estimated from 220 − age — the estimate says so on screen,
    /// which makes the trailing text two characters wider and is its own width to measure.
    let measured: Bool

    var body: some View {
        HStack {
            SectionLabel("Time in zone")
            Spacer()
            Text("MAX HR \(maxHR)\(measured ? "" : " EST")")
                .font(Tokens.Font.mono(10)).tracking(1)
                .foregroundStyle(Tokens.Palette.textTertiary)
        }
    }
}

struct ElevationHeaderRow: View {
    /// Gain and loss, already in the athlete's unit and uppercased, or nil when the run
    /// carries neither.
    let summary: String?

    var body: some View {
        HStack {
            SectionLabel("Elevation")
            Spacer()
            if let summary {
                Text(summary)
                    .font(Tokens.Font.mono(10)).tracking(1)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
    }
}

// MARK: - Store (DB extras + cached coach takeaway)

@MainActor
final class RunDetailStore: ObservableObject {
    @Published var detail: RunDetail?
    @Published var loading = true
    @Published var takeaway: String?
    @Published var takeawayLoading = true
    @Published var correctionNote: String?
    /// This run's sub-distance efforts (#25). Empty until the archive scan has reached this
    /// run — and empty is also the right answer for a run too short to hold any.
    @Published var efforts: [BestEfforts.Effort] = []
    /// The run has a `runs` row this page could read — so a journal edit has somewhere to go.
    @Published var rowExists = false
    /// The journal photo (#124), and the object key it is the photo for.
    @Published var photo: UIImage?
    @Published var photoFailed = false
    private var photoKey: String?

    private var started = false

    /// Fetch the photo for `key`, unless it is already the one held. Nil clears it.
    func loadPhoto(key: String?) async {
        guard key != photoKey || (photo == nil && !photoFailed) else { return }
        photoKey = key
        photo = nil
        photoFailed = false
        guard let key else { return }
        let image = await RunJournal.loadPhoto(objectKey: key)
        // A newer key may have arrived while this one downloaded (an edit replaced it).
        guard key == photoKey else { return }
        photo = image
        photoFailed = image == nil
    }

    /// An edit just landed this photo (or took it away): show the image already in hand
    /// rather than signing and downloading what was just uploaded.
    func adoptPhoto(_ image: UIImage?, key: String?) {
        photoKey = key
        photo = key == nil ? nil : image
        photoFailed = key != nil && image == nil
    }

    func load(run: RunSummary, runStore: RunStore) async {
        guard !started else { return }
        started = true

        async let hkDetail = RunDetailLoader().load(run: run, maxHR: runStore.effectiveMaxHR)

        struct Extras: Decodable { let coach_takeaway: String?; let correction_note: String? }
        let extras: Extras? = try? await Supa.client
            .from("runs")
            .select("coach_takeaway,correction_note")
            .eq("id", value: run.id.uuidString)
            .single()
            .execute()
            .value

        detail = await hkDetail
        loading = false
        rowExists = extras != nil
        correctionNote = extras?.correction_note
        if runStore.bestEfforts.available {
            efforts = await BestEffortsService().efforts(for: run.id)
        }

        if let cached = extras?.coach_takeaway {
            takeaway = cached
            takeawayLoading = false
            return
        }
        takeawayLoading = true
        takeaway = await TakeawayService.ensureTakeaway(for: run, detail: detail, store: runStore)
        takeawayLoading = false
    }
}

#Preview {
    NavigationStack {
        RunDetailView(run: RunSummary(id: UUID(), start: .now, distanceM: 9656, durationS: 3312, avgHR: 144))
            .environmentObject(RunStore())
            .environmentObject(TabRouter())
    }
    .preferredColorScheme(.dark)
}
