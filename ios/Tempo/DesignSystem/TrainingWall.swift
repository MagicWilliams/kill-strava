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

    private func grid(_ block: RunHistory.YearBlock) -> some View {
        let width = CGFloat(block.weeks.count) * (cell + gap) - gap
        let height = 7 * (cell + gap) - gap

        return HStack(alignment: .top, spacing: gap) {
            ForEach(Array(block.weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(color(for: week[row]))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(scrub(block, width: width, height: height))
    }

    /// Maps a finger position onto a cell. Chart-style scrubbing, because a 4.5pt tap
    /// target would be unusable and shrinking the year to make one wouldn't be a wall.
    private func scrub(_ block: RunHistory.YearBlock, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let col = Int(value.location.x / (cell + gap))
                let row = Int(value.location.y / (cell + gap))
                guard block.weeks.indices.contains(col), (0..<7).contains(row),
                      let day = block.weeks[col][row] else { return }
                if day != selected { selected = day }
            }
    }

    private func color(for day: RunHistory.Day?) -> Color {
        guard let day else { return .clear }
        if day == selected { return Tokens.Palette.textPrimary }
        switch day.level {
        case 0:  return Tokens.Palette.inset
        case 1:  return Tokens.Palette.volt.opacity(0.25)
        case 2:  return Tokens.Palette.volt.opacity(0.45)
        case 3:  return Tokens.Palette.volt.opacity(0.7)
        default: return Tokens.Palette.volt
        }
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
                        Text(String(format: "%.1f mi", day.miles)).mono(13, Tokens.Palette.volt)
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
