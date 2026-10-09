import SwiftUI
import Charts
import CoreLocation

/// The goal race, read back. Pushed from the "Race recap" card on `RunDetailView`, which only
/// appears on the run `RaceRecap.isRace` picks out. All arithmetic is in `RaceRecap`; this
/// view draws it.
///
/// Times here are **elapsed** (the race clock), not moving time. Everywhere else in the app
/// the default is moving time, but a race result is the chip clock: standing at an aid
/// station is part of your marathon.
struct RaceRecapView: View {
    let run: RunSummary

    @EnvironmentObject private var store: RunStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var detail: RunDetail?
    @State private var recap: RaceRecap.Recap?
    @State private var loading = true
    @State private var shareImage: Image?

    private var goal: GoalInfo? { store.goal }
    private var raceMeters: Double { RaceRecap.raceMeters(goalDistance: goal?.distance) }
    private var raceName: String {
        goal?.raceName.flatMap { $0.isEmpty ? nil : $0 } ?? RaceCountdown.unnamedRace
    }
    private var goalS: Int? { goal?.goalTimeSeconds.flatMap { $0 > 0 ? $0 : nil } }

    /// The series' finish mat when there is one; otherwise the stored wall clock.
    private var finishS: Double {
        recap?.finishS ?? Double(run.elapsedS ?? run.durationS)
    }
    private var finishDeltaS: Double? { goalS.map { finishS - Double($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hero
                routeCard
                if let recap {
                    matsCard(recap)
                    if recap.goalS != nil, recap.mats.count > 1 { deltaChart(recap) }
                    halvesCard(recap)
                } else if !loading {
                    Card {
                        SectionLabel("Mats")
                        Text("No distance samples in Apple Health for this run, so there's nothing to place the mats on. The finish time above is the stored clock.")
                            .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
                    }
                }
                blockCard
                shareCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        guard loading else { return }
        let loaded = await RunDetailLoader().load(run: run, maxHR: store.effectiveMaxHR)
        detail = loaded
        if let loaded {
            recap = RaceRecap.recap(
                times: loaded.cumulativeTimesS,
                meters: loaded.cumulativeMeters,
                hrTimes: loaded.hrTimesS,
                hrBPM: loaded.hrBPM,
                raceMeters: raceMeters,
                goalS: goalS
            )
        }
        loading = false
        renderShareImage()
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
            SectionLabel("Race recap", color: Tokens.Palette.accentText)
            Spacer()
            if loading { ProgressView().controlSize(.small).tint(Tokens.Palette.textTertiary) }
        }
        .padding(.top, 8)
    }

    private var hero: some View {
        Card(well: .accent) {
            VStack(alignment: .leading, spacing: 2) {
                Text(raceName).display(26)
                Text(run.start.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Text(RaceRecap.formatClock(finishS)).display(52)
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    SectionLabel("Goal")
                    Text(goalS.map(PaceModel.formatFinish) ?? GoalLine.unknownFinish)
                        .mono(15, Tokens.Palette.textSecondary)
                }
                if let delta = finishDeltaS { deltaTag(delta, suffix: delta < 0 ? " under goal" : " over goal") }
                Spacer()
            }
            Text("Watch clock, start to finish — set it beside your official chip time.")
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    private func deltaTag(_ delta: Double, suffix: String = "") -> some View {
        let banked = delta.rounded() <= 0
        return Tag(
            text: RaceRecap.formatDelta(delta) + suffix,
            fg: banked ? Tokens.Palette.success : Tokens.Palette.warning,
            bg: banked ? Tokens.Well.success.insetFill : Tokens.Well.warning.insetFill
        )
    }

    private func deltaColor(_ delta: Double?) -> Color {
        guard let delta else { return Tokens.Palette.textTertiary }
        if delta.rounded() == 0 { return Tokens.Palette.textSecondary }
        return delta < 0 ? Tokens.Palette.success : Tokens.Palette.warning
    }

    // MARK: - Map

    @ViewBuilder private var routeCard: some View {
        if let detail, detail.hasRoute {
            RunRouteMap(detail: detail)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
        } else {
            ZStack {
                Tokens.Palette.inset
                VStack(spacing: 7) {
                    Image(systemName: loading ? "map" : "figure.run")
                        .font(.system(size: 22)).foregroundStyle(Tokens.Palette.textTertiary)
                    Text(loading ? "Loading route…" : detail?.isIndoor == true ? "Indoor run" : "No route data")
                        .font(Tokens.Font.mono(12)).tracking(1.2).foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
        }
    }

    // MARK: - Mats table

    private func matsCard(_ recap: RaceRecap.Recap) -> some View {
        Card {
            HStack {
                SectionLabel("The mats")
                Spacer()
                if recap.goalS != nil {
                    Text("± VS GOAL PACE").mono(9, Tokens.Palette.textTertiary).tracking(1)
                }
            }
            HStack {
                Text("MAT").frame(width: 50, alignment: .leading)
                Text("CLOCK").frame(width: 76, alignment: .leading)
                Text("PACE").frame(width: 56, alignment: .leading)
                Spacer()
                Text("±").frame(width: 64, alignment: .trailing)
            }
            .font(Tokens.Font.mono(10)).foregroundStyle(Tokens.Palette.textTertiary)

            ForEach(recap.mats) { mat in
                HStack {
                    Text(mat.label)
                        .mono(12, mat.isFinish ? Tokens.Palette.textPrimary : Tokens.Palette.textSecondary)
                        .frame(width: 50, alignment: .leading)
                    Text(RaceRecap.formatClock(mat.elapsedS)).mono(12).frame(width: 76, alignment: .leading)
                    Text(PaceModel.format(Int(mat.segmentPaceSecPerMile.rounded())))
                        .mono(12, Tokens.Palette.textSecondary).frame(width: 56, alignment: .leading)
                    if recap.fadePoint?.id == mat.id {
                        Tag(text: "fade", fg: Tokens.Palette.warning, bg: Tokens.Well.warning.insetFill)
                    }
                    Spacer()
                    Text(mat.deltaS.map(RaceRecap.formatDelta) ?? "–")
                        .mono(12, deltaColor(mat.deltaS)).frame(width: 64, alignment: .trailing)
                }
                .frame(height: 24)
            }
            HStack(spacing: 14) {
                legendDot(Tokens.Palette.success, "BANKED")
                legendDot(Tokens.Palette.warning, "GIVEN BACK")
                Spacer()
                Text("PACE /MI").mono(9, Tokens.Palette.textTertiary).tracking(1)
            }
            Text(distanceNote(recap))
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    private func distanceNote(_ recap: RaceRecap.Recap) -> String {
        let measuredMi = recap.measuredMeters / RaceRecap.metersPerMile
        let raceMi = recap.raceMeters / RaceRecap.metersPerMile
        if recap.wasScaled {
            return String(format: "Your watch read %.2f mi. GPS reads long between tall buildings, so every distance was scaled by %.3f to put the finish on %.1f — that's what puts the mats where the real ones are.", measuredMi, recap.scale, raceMi)
        }
        if recap.measuredMeters > recap.raceMeters {
            return String(format: "Your watch read %.2f mi — too far over to be GPS drift, so the mats use the raw distance.", measuredMi)
        }
        return String(format: "Your watch read %.2f mi, short of the course, so the finish is placed at the end of the recording.", measuredMi)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Tokens.Font.mono(9)).tracking(1).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    // MARK: - Delta chart

    private struct ChartPoint: Identifiable {
        let id: Int
        let km: Double
        /// Seconds ahead of goal — the delta negated, so ahead plots *up*.
        let ahead: Double
    }

    private func deltaChart(_ recap: RaceRecap.Recap) -> some View {
        let points = [ChartPoint(id: -1, km: 0, ahead: 0)] + recap.mats.compactMap { mat in
            mat.deltaS.map { ChartPoint(id: mat.id, km: mat.meters / 1000, ahead: -$0) }
        }
        let fade = recap.fadePoint.flatMap { f in points.first { $0.id == f.id } }
        let extent = max(points.map { abs($0.ahead) }.max() ?? 0, 30)
        return Card {
            HStack {
                SectionLabel("Against the goal")
                Spacer()
                Text("UP = AHEAD").mono(9, Tokens.Palette.textTertiary).tracking(1)
            }
            Chart {
                RuleMark(y: .value("Goal", 0))
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                ForEach(points) { p in
                    AreaMark(x: .value("km", p.km), y: .value("Ahead", p.ahead))
                        .foregroundStyle(Tokens.Palette.voltMark.opacity(0.18))
                    LineMark(x: .value("km", p.km), y: .value("Ahead", p.ahead))
                        .foregroundStyle(Tokens.Palette.accentText)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("km", p.km), y: .value("Ahead", p.ahead))
                        .foregroundStyle(Tokens.Palette.accentText)
                        .symbolSize(18)
                }
                if let fade {
                    PointMark(x: .value("km", fade.km), y: .value("Ahead", fade.ahead))
                        .foregroundStyle(Tokens.Palette.warning)
                        .symbolSize(90)
                        .annotation(position: .top, spacing: 4) {
                            Text("FADE").mono(9, Tokens.Palette.warning).tracking(1)
                        }
                }
            }
            .chartYScale(domain: -extent * 1.25 ... extent * 1.25)
            .chartXAxis {
                AxisMarks(values: [0, 10, 20, 30, 40]) { _ in
                    AxisValueLabel().font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Tokens.Palette.divider.opacity(0.5))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(RaceRecap.formatDelta(-v)).font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                        }
                    }
                }
            }
            .frame(height: 170)
            Text(fadeCaption(recap))
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    private func fadeCaption(_ recap: RaceRecap.Recap) -> String {
        guard let fade = recap.fadePoint, let d = fade.deltaS, let finish = recap.finishDeltaS else {
            return "No fade — you were never further ahead of goal than at the finish."
        }
        return "Most banked at \(fade.label) (\(RaceRecap.formatDelta(d))). From there to the line you gave back \(RaceRecap.formatClock(finish - d))."
    }

    // MARK: - Halves + HR drift

    private func halvesCard(_ recap: RaceRecap.Recap) -> some View {
        let tiles: [(String, String)] = {
            var t: [(String, String)] = []
            if let h = recap.halves {
                t.append(("1ST HALF", RaceRecap.formatClock(h.firstS)))
                t.append(("2ND HALF", RaceRecap.formatClock(h.secondS)))
                t.append((h.isNegativeSplit ? "NEGATIVE SPLIT" : "POSITIVE SPLIT", RaceRecap.formatDelta(h.splitS)))
            }
            if let drift = recap.hrDrift {
                t.append(("HR DRIFT", String(format: "%+.0f bpm · %+.1f%%", drift.bpm, drift.percent)))
            } else {
                t.append(("HR DRIFT", "—"))
            }
            return t
        }()
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    StatTile(value: tile.1, label: tile.0)
                }
            }
            if let drift = recap.hrDrift {
                Text(String(format: "Average HR %.0f bpm in the first half, %.0f in the second.", drift.firstHalfBPM, drift.secondHalfBPM))
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
            } else {
                Text("Too few heart-rate samples in Apple Health to compare the halves.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
    }

    // MARK: - The block

    @ViewBuilder private var blockCard: some View {
        let block = RaceRecap.block(runs: store.runs, raceDay: run.start, raceMeters: raceMeters)
        Card(well: .cool) {
            SectionLabel("The block that got you here")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                blockTile(String(format: "%.0f mi", block.miles), "\(RaceRecap.blockWeeks) weeks · \(block.runCount) runs")
                blockTile(block.longest.map { String(format: "%.1f mi", $0.miles) } ?? "—",
                          "Longest" + (block.longest.map { " · " + $0.start.formatted(.dateTime.month(.abbreviated).day()) } ?? ""))
                if raceMeters == RaceRecap.marathonMeters {
                    blockTile(block.projectedFinishS.map(PaceModel.formatFinish) ?? GoalLine.unknownFinish, "Projected that morning")
                    blockTile(RaceRecap.formatClock(finishS), "Actual")
                }
            }
            if let projected = block.projectedFinishS, raceMeters == RaceRecap.marathonMeters {
                let diff = finishS - Double(projected)
                Text(diff <= 0
                     ? "\(RaceRecap.formatClock(-diff)) faster than the projection said you were ready for."
                     : "\(RaceRecap.formatClock(diff)) slower than the projection on race morning.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

    private func blockTile(_ value: String, _ label: String) -> some View {
        InsetWell(padding: 12) {
            Text(value).display(20)
            SectionLabel(label)
        }
    }

    // MARK: - Share

    @ViewBuilder private var shareCard: some View {
        Card {
            SectionLabel("Share")
            if let shareImage {
                shareImage
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
                ShareLink(item: shareImage, preview: SharePreview("\(raceName) recap", image: shareImage)) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share recap").font(Tokens.Font.ui(16, .bold))
                    }
                    .foregroundStyle(Tokens.Palette.onVolt)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Tokens.Palette.volt)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
                }
                .buttonStyle(Pressable())
            } else {
                Text(loading ? "Rendering…" : "Couldn't render the share card.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
    }

    @MainActor private func renderShareImage() {
        let card = RaceShareCard(
            raceName: raceName,
            date: run.start,
            finishS: finishS,
            goalS: goalS,
            halves: recap?.halves,
            route: detail?.routeSegments ?? []
        )
        // Always the dark poster, whatever the phone's appearance: it is an image that leaves
        // the app, and volt on near-black is the one combination that reads anywhere.
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = displayScale
        if let ui = renderer.uiImage { shareImage = Image(uiImage: ui) }
    }
}

// MARK: - Share card

/// One fixed-size poster for `ImageRenderer`. MapKit doesn't render offscreen, so the route
/// is redrawn here as plain paths in the same pace colours.
private struct RaceShareCard: View {
    let raceName: String
    let date: Date
    let finishS: Double
    let goalS: Int?
    let halves: RaceRecap.Halves?
    let route: [RunDetail.RouteSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(raceName.uppercased()).font(Tokens.Font.mono(13)).tracking(2)
                    .foregroundStyle(Tokens.Palette.accentText)
                Spacer()
                Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textTertiary)
            }
            RouteSketch(segments: route)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
            Text(RaceRecap.formatClock(finishS)).display(64)
            HStack(spacing: 18) {
                if let goalS {
                    stat("GOAL", PaceModel.formatFinish(goalS))
                    stat(finishS <= Double(goalS) ? "UNDER" : "OVER", RaceRecap.formatDelta(finishS - Double(goalS)))
                }
                if let halves {
                    stat("SPLIT", RaceRecap.formatDelta(halves.splitS))
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Text("TEMPO").font(Tokens.Font.display(14)).tracking(2)
                    .foregroundStyle(Tokens.Palette.onVolt)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Tokens.Palette.volt, in: Capsule())
            }
        }
        .padding(24)
        .frame(width: 360, height: 520)
        .background(Tokens.Palette.canvas)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Tokens.Font.mono(17)).foregroundStyle(Tokens.Palette.textPrimary)
            Text(label).font(Tokens.Font.mono(10)).tracking(1.5).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }
}

/// The route as bare strokes, fitted to the frame with longitude corrected for latitude so
/// the shape isn't stretched east–west.
private struct RouteSketch: View {
    let segments: [RunDetail.RouteSegment]

    var body: some View {
        GeometryReader { geo in
            let coords = segments.flatMap(\.coords)
            if let first = coords.first {
                let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
                let minLat = lats.min()!, maxLat = lats.max()!
                let minLon = lons.min()!, maxLon = lons.max()!
                let k = cos(first.latitude * .pi / 180)
                let w = max((maxLon - minLon) * k, 1e-6), h = max(maxLat - minLat, 1e-6)
                let scale = min(geo.size.width / w, geo.size.height / h) * 0.92
                let ox = (geo.size.width - w * scale) / 2, oy = (geo.size.height - h * scale) / 2
                let project: (CLLocationCoordinate2D) -> CGPoint = { c in
                    CGPoint(x: ox + (c.longitude - minLon) * k * scale, y: oy + (maxLat - c.latitude) * scale)
                }
                ForEach(segments) { seg in
                    Path { p in
                        guard let s = seg.coords.first else { return }
                        p.move(to: project(s))
                        for c in seg.coords.dropFirst() { p.addLine(to: project(c)) }
                    }
                    .stroke(Tokens.Zone.all[seg.zone], style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            } else {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 48))
                    .foregroundStyle(Tokens.Palette.voltMark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
