import SwiftUI

/// Every day of training as one small square — five years of running on one screen.
///
/// Cells are ~4.5pt so a full 53-week year fits the card width without scrolling, which is
/// the whole point: you see the shape of a season, the injury gap, the taper. That's far
/// below a tappable target, so selection is a *scrub* rather than a tap — drag across the
/// wall and the readout above follows your finger. The readout itself is a real 44pt row,
/// and that's what opens the run.
struct TrainingWall: View {
    let blocks: [RunHistory.YearBlock]
    let onOpen: (UUID) -> Void

    @State private var selected: RunHistory.Day?

    private let cell: CGFloat = 4.5
    private let gap: CGFloat = 1

    var body: some View {
        Card {
            HStack {
                SectionLabel("Training wall")
                Spacer()
                legend
            }

            readout

            ForEach(blocks) { block in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(block.year)).mono(11, Tokens.Palette.textPrimary)
                        Spacer()
                        Text("\(block.runCount) runs · \(block.miles, specifier: "%.0f") mi")
                            .mono(10, Tokens.Palette.textTertiary)
                    }
                    grid(block)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Grid

    /// Drawn with `Canvas`, not a grid of `RoundedRectangle`s.
    ///
    /// A year is 371 cells; six years of archive would be ~2,200 SwiftUI views in one
    /// scroll section, each with its own identity and layout pass, for something that is
    /// visually one picture. Canvas draws the whole year in a single immediate-mode pass.
    /// Nothing is lost: hit testing was never per-cell — the scrub already maps a finger
    /// position onto a cell arithmetically.
    private func grid(_ block: RunHistory.YearBlock) -> some View {
        let width = CGFloat(block.weeks.count) * (cell + gap) - gap
        let height = 7 * (cell + gap) - gap

        return Canvas { context, _ in
            for (col, week) in block.weeks.enumerated() {
                for row in 0..<7 {
                    guard let day = week[row] else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * (cell + gap),
                        y: CGFloat(row) * (cell + gap),
                        width: cell,
                        height: cell
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1, style: .continuous),
                        with: .color(color(for: day))
                    )
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(scrub(block, width: width, height: height))
        // Warm the generator before the finger lands, so the first tick of a scrub isn't
        // the one that arrives late.
        .onAppear { Haptics.warmUp() }
    }

    /// Maps a finger position onto a cell. Chart-style scrubbing, because a 4.5pt tap
    /// target would be unusable and shrinking the year to make one wouldn't be a wall.
    ///
    /// One selection tick per cell crossed. At 4.5pt a cell is smaller than the finger
    /// covering it, so the readout above is the only thing telling you where you are —
    /// and looking up to check costs you your place. The haptic is what lets you feel the
    /// grid instead of watching it, which is the difference between scrubbing a year and
    /// hunting for a day.
    private func scrub(_ block: RunHistory.YearBlock, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let col = Int(value.location.x / (cell + gap))
                let row = Int(value.location.y / (cell + gap))
                guard block.weeks.indices.contains(col), (0..<7).contains(row),
                      let day = block.weeks[col][row] else { return }
                if day != selected {
                    selected = day
                    Haptics.select()
                }
            }
    }

    private func color(for day: RunHistory.Day?) -> Color {
        guard let day else { return .clear }
        if day == selected { return Tokens.Palette.textPrimary }
        return Tokens.Wall.ramp[min(day.level, Tokens.Wall.ramp.count - 1)]
    }

    // MARK: - Readout + legend

    @ViewBuilder private var readout: some View {
        if let day = selected {
            Button {
                if let first = day.runIDs.first { onOpen(first) }
            } label: {
                HStack(spacing: 8) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                        .font(Tokens.Font.ui(13, .medium))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                    Spacer()
                    if day.didRun {
                        Text(String(format: "%.1f mi", day.miles)).mono(13, Tokens.Palette.accentText)
                        if day.runCount > 1 {
                            Text("×\(day.runCount)").mono(11, Tokens.Palette.textTertiary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10)).foregroundStyle(Tokens.Palette.textTertiary)
                    } else {
                        Text("rest").mono(12, Tokens.Palette.textTertiary)
                    }
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            .disabled(!day.didRun)
        } else {
            Text("Drag across the wall to read a day.")
                .font(Tokens.Font.ui(12))
                .foregroundStyle(Tokens.Palette.textTertiary)
                .frame(height: 44, alignment: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("LESS").mono(9, Tokens.Palette.textTertiary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color(for: RunHistory.Day(
                        date: .distantPast,
                        miles: [0, 2, 6, 10, 20][level],
                        runCount: level == 0 ? 0 : 1,
                        runIDs: []
                    )))
                    .frame(width: 6, height: 6)
            }
            Text("MORE").mono(9, Tokens.Palette.textTertiary)
        }
    }
}
