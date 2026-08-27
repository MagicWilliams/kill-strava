import SwiftUI
import Charts
import MapKit
import Supabase

/// Per-run deep dive: pace-colored route map, the coach's cached read, Garmin-style
/// stats, scrubbable pace+HR chart, time-in-zone, elevation, and mile splits.
/// Spec: progress.md → "Run Detail spec".
struct RunDetailView: View {
    let run: RunSummary

    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RunDetailStore()
    @State private var showFullMap = false
    @State private var scrub: RunDetail.SeriesPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    VStack(alignment: .leading, spacing: 16) {
                        titleRow
                        heroStats
                        coachRead
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
                        if let detail = model.detail, detail.splits.count > 1 {
                            splitsCard(detail)
                        }
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
        .fullScreenCover(isPresented: $showFullMap) { fullMap }
    }

    // MARK: - Hero

    @ViewBuilder private var hero: some View {
        if let detail = model.detail, detail.hasRoute {
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
        Map(initialPosition: .region(region(for: detail)), interactionModes: interactive ? .all : []) {
            ForEach(detail.routeSegments) { seg in
                MapPolyline(coordinates: seg.coords)
                    .stroke(Tokens.Zone.all[seg.zone], style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private func region(for detail: RunDetail) -> MKCoordinateRegion {
        let coords = detail.routeSegments.flatMap(\.coords)
        guard let first = coords.first else {
            return MKCoordinateRegion(center: .init(latitude: 0, longitude: 0), span: .init(latitudeDelta: 1, longitudeDelta: 1))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max((maxLat - minLat) * 1.4, 0.004),
                        longitudeDelta: max((maxLon - minLon) * 1.4, 0.004))
        )
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
        .preferredColorScheme(.dark)
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

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(run.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(Tokens.Font.display(24)).foregroundStyle(Tokens.Palette.textPrimary)
                if run.corrected {
                    Tag(text: "edited", fg: Tokens.Palette.info, bg: Tokens.Palette.inset)
                }
            }
            Text(run.start.formatted(date: .omitted, time: .shortened) + (run.source == "manual" ? " · logged manually" : ""))
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
        .padding(.top, 14)
    }

    private var coachRead: some View {
        Card(glow: true) {
            HStack {
                SectionLabel("Coach's read", color: Tokens.Palette.accentText)
                Spacer()
                if model.takeawayLoading {
                    ProgressView().controlSize(.small).tint(Tokens.Palette.textTertiary)
                }
            }
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

    // MARK: - Stats

    /// Big distance number + the two facts you check first. Corrected DB totals win.
    private var heroStats: some View {
        let d = model.detail
        let corrected = run.corrected
        let miles = corrected ? run.miles : (d?.miles ?? run.miles)
        let pace = corrected ? run.paceSecPerMile : (d?.avgPaceSec ?? run.paceSecPerMile)
        let time = corrected ? run.durationS : (d?.timerS ?? run.durationS)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%.2f", miles))
                .font(Tokens.Font.display(52)).foregroundStyle(Tokens.Palette.textPrimary)
            Text("MI").font(Tokens.Font.mono(14)).tracking(1.5).foregroundStyle(Tokens.Palette.textTertiary)
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                if let pace {
                    Text(PaceModel.format(pace) + " /mi").mono(16)
                }
                Text(format(seconds: time)).mono(14, Tokens.Palette.textSecondary)
            }
        }
        .padding(.top, -4)
    }

    private var statsGrid: some View {
        let d = model.detail
        // A corrected run's DB totals are the truth — raw HealthKit only covers the
        // recorded portion, so its time-accounting tiles are hidden to avoid contradiction.
        let corrected = run.corrected
        let stats: [(String, String)?] = [
            corrected ? nil : d?.elapsedPaceSec.map { ("ELAPSED PACE", PaceModel.format($0) + " /mi") },
            d?.bestPaceSec.map { ("BEST PACE", PaceModel.format($0) + " /mi") },
            corrected ? nil : d?.avgSpeedMph.map { ("AVG SPEED", String(format: "%.1f mph", $0)) },
            corrected ? nil : d.map { ("MOVING TIME", format(seconds: $0.movingS)) },
            corrected ? nil : d.map { ("ELAPSED TIME", format(seconds: $0.elapsedS)) },
            (run.avgHR ?? d?.avgHR).map { ("AVG HR", "\($0) bpm") },
            d?.maxHR.map { ("MAX HR", "\($0) bpm") },
            d?.elevGainM.map { ("ELEV GAIN", String(format: "%.0f ft", $0 * 3.28084)) },
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
            HStack {
                SectionLabel("Pace + Heart rate")
                Spacer()
                legendDot(Tokens.Palette.accentText, "PACE")
                legendDot(Tokens.Zone.z5, "HR")
            }
            scrubReadout(detail)
            Chart {
                ForEach(detail.series) { p in
                    if let pace = p.paceSecPerMile {
                        LineMark(
                            x: .value("Miles", p.miles),
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
                            x: .value("Miles", p.miles),
                            y: .value("HR", normalizedHR(hr, detail)),
                            series: .value("Series", "hr")
                        )
                        .foregroundStyle(Tokens.Zone.z5.opacity(0.85))
                        .interpolationMethod(.catmullRom)
                    }
                }
                if let scrub {
                    RuleMark(x: .value("Miles", scrub.miles))
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
                                    if let miles: Double = proxy.value(atX: x) {
                                        scrub = detail.series.min(by: { abs($0.miles - miles) < abs($1.miles - miles) })
                                    }
                                }
                                .onEnded { _ in scrub = nil }
                        )
                }
            }
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Tokens.Font.mono(9)).tracking(1).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    @ViewBuilder private func scrubReadout(_ detail: RunDetail) -> some View {
        let mile = scrub.map { String(format: "MI %.2f", $0.miles) } ?? "FULL RUN"
        let pace = scrub?.paceSecPerMile.map { PaceModel.format(Int($0)) + " /mi" }
            ?? detail.avgPaceSec.map { PaceModel.format($0) + " /mi avg" }
        let hr = scrub?.hr.map { "\(Int($0)) bpm" } ?? detail.avgHR.map { "\($0) bpm avg" }
        let elev = scrub?.elevationM.map { String(format: "%.0f ft", $0 * 3.28084) }
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
            HStack {
                SectionLabel("Time in zone")
                Spacer()
                Text("MAX HR \(store.effectiveMaxHR)\(store.maxHRIsMeasured ? "" : " EST")")
                    .font(Tokens.Font.mono(10)).tracking(1)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
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
        Card {
            HStack {
                SectionLabel("Elevation")
                Spacer()
                if let gain = detail.elevGainM, let loss = detail.elevLossM {
                    Text(String(format: "↑ %.0f FT · ↓ %.0f FT", gain * 3.28084, loss * 3.28084))
                        .font(Tokens.Font.mono(10)).tracking(1)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
            Chart {
                ForEach(detail.series) { p in
                    if let elev = p.elevationM {
                        AreaMark(x: .value("Miles", p.miles), y: .value("Elev", elev * 3.28084))
                            .foregroundStyle(
                                LinearGradient(colors: [Tokens.Palette.voltMark.opacity(0.35), Tokens.Palette.voltMark.opacity(0.02)],
                                               startPoint: .top, endPoint: .bottom)
                            )
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Miles", p.miles), y: .value("Elev", elev * 3.28084))
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
        let fastest = detail.splits.map(\.paceSec).min() ?? 1
        return Card {
            SectionLabel("Splits")
            HStack {
                Text("MI").mono(10, Tokens.Palette.textTertiary).frame(width: 26, alignment: .leading)
                Text("PACE").mono(10, Tokens.Palette.textTertiary).frame(width: 48, alignment: .leading)
                Spacer()
                Text("HR").mono(10, Tokens.Palette.textTertiary).frame(width: 36, alignment: .trailing)
                Text("ELEV").mono(10, Tokens.Palette.textTertiary).frame(width: 44, alignment: .trailing)
            }
            ForEach(detail.splits) { split in
                HStack {
                    Text(split.miles < 0.99 ? String(format: "%.1f", split.miles) : "\(split.id)")
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
                    Text(split.elevDeltaM.map { String(format: "%+.0f", $0 * 3.28084) } ?? "–")
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

// MARK: - Store (DB extras + cached coach takeaway)

@MainActor
final class RunDetailStore: ObservableObject {
    @Published var detail: RunDetail?
    @Published var loading = true
    @Published var takeaway: String?
    @Published var takeawayLoading = true
    @Published var correctionNote: String?

    private var started = false

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
        correctionNote = extras?.correction_note

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
