import SwiftUI

/// Shoes, on You (#121): every pair in service with its mileage, the retired ones folded
/// away, and the nudge when a pair is getting close to done.
///
/// Mileage is summed from `store.runs` — the runs already on the phone — so it moves the
/// moment a tagged run syncs, with no shoe read of its own. All the arithmetic is in
/// `ShoeMileage`; this view draws it.
struct ShoesCard: View {
    @EnvironmentObject private var store: RunStore
    @Environment(\.units) private var units
    @StateObject private var shoes = ShoeStore()
    @AppStorage(ShoeStore.retirementMilesKey) private var retirementMiles = ShoeMileage.defaultRetirementMiles

    @State private var adding = false
    @State private var retiring: Shoe?
    @State private var showRetired = false
    @State private var failure: String?

    private var threshold: Int { ShoeMileage.clampedThreshold(retirementMiles) }

    /// The retirement bar is a whole-mile setting (300–500 mi). In km it is said as the
    /// whole kilometres it comes to, "644 km", rather than re-cut into a km scale: the
    /// setting itself didn't change, only how it reads.
    private func wholeUnits(miles: Double) -> String {
        units.formatDistance(miles: miles, decimals: 0)
    }

    var body: some View {
        let tallies = ShoeMileage.tallies(shoes.shoes, runs: store.runs.map(ShoeMileage.Run.init))
        let (active, retired) = ShoeMileage.ordered(shoes.shoes)

        Card {
            HStack {
                SectionLabel("Shoes")
                Spacer()
                if shoes.phase == .ready {
                    Button { adding = true } label: {
                        Label("Add a pair", systemImage: "plus")
                            .font(Tokens.Font.ui(12, .semibold)).foregroundStyle(Tokens.Palette.accentText)
                    }
                    .buttonStyle(Pressable())
                }
            }

            switch shoes.phase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 36)
            case .unavailable:
                Text("Couldn't load your shoes.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                Button { Task { await shoes.load() } } label: {
                    Text("Try again").font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.accentText)
                }
                .buttonStyle(Pressable())
            case .ready:
                if active.isEmpty && retired.isEmpty {
                    Text("Add the pairs you run in. Each run you tag adds to its pair's mileage, and Tempo tells you when one gets close to \(wholeUnits(miles: Double(threshold))).")
                        .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                }
                ForEach(active) { shoe in
                    activeRow(shoe, tallies[shoe.id] ?? ShoeMileage.tally(shoe, runs: []))
                }
                if !retired.isEmpty { retiredSection(retired, tallies) }
                if !shoes.shoes.isEmpty { thresholdRow }
            }

            if let failure {
                Text(failure).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.danger)
            }
        }
        .motion(Motion.reveal, value: showRetired)
        .task { await shoes.load() }
        .sheet(isPresented: $adding) {
            AddShoeSheet(firstPair: active.isEmpty) { draft, makeDefault in
                guard let shoe = await shoes.add(draft) else { return false }
                if makeDefault { shoes.setDefault(shoe.id) }
                failure = nil
                return true
            }
        }
        .confirmationDialog(
            retiring.map { "Retire \($0.name)?" } ?? "",
            isPresented: Binding(get: { retiring != nil }, set: { if !$0 { retiring = nil } }),
            titleVisibility: .visible,
            presenting: retiring
        ) { shoe in
            Button("Retire", role: .destructive) {
                Task {
                    failure = await shoes.retire(shoe) ? nil : "Couldn't retire \(shoe.name). Try again."
                }
            }
        } message: { _ in
            Text("It keeps its mileage and moves to Retired. It won't be offered after a run.")
        }
    }

    // MARK: - Rows

    /// Tap for the actions: default, retire. A Menu rather than swipe actions — this is a
    /// card in a scroll view, not a List, and a swipe there fights the scroll.
    private func activeRow(_ shoe: Shoe, _ tally: ShoeMileage.Tally) -> some View {
        let isDefault = shoes.defaultShoeID == shoe.id
        return Menu {
            if isDefault {
                Button("Remove as default", systemImage: "star.slash") { shoes.setDefault(nil) }
            } else {
                Button("Make default", systemImage: "star") { shoes.setDefault(shoe.id) }
            }
            Button("Retire…", systemImage: "archivebox", role: .destructive) { retiring = shoe }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(shoe.name)
                        .font(Tokens.Font.ui(14, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                        .lineLimit(1)
                    if isDefault {
                        // Volt as a fill with onVolt on it — the one legal way to wear it.
                        Tag(text: "Default", fg: Tokens.Palette.onVolt, bg: Tokens.Palette.volt)
                    }
                    Spacer()
                    Text(Self.distanceLabel(tally.miles, units))
                        .font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.textPrimary)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12)).foregroundStyle(Tokens.Palette.textTertiary)
                }
                Text("\(tally.runs) \(tally.runs == 1 ? "run" : "runs") · since \(shoe.startedAt.formatted(.dateTime.month(.abbreviated).day().year()))")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
                wearHint(ShoeMileage.wear(tally, thresholdMiles: threshold, retired: false))
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }

    @ViewBuilder private func wearHint(_ wear: ShoeMileage.Wear) -> some View {
        switch wear {
        case .fine:
            EmptyView()
        case .nearing(let left):
            Text("\(wholeUnits(miles: Double(left))) to \(units.number(miles: Double(threshold), decimals: 0)) — time to line up the next pair.")
                .font(Tokens.Font.ui(12, .medium)).foregroundStyle(Tokens.Palette.warning)
        case .due:
            Text("Past \(wholeUnits(miles: Double(threshold))) — worth retiring.")
                .font(Tokens.Font.ui(12, .medium)).foregroundStyle(Tokens.Palette.warning)
        }
    }

    @ViewBuilder private func retiredSection(_ retired: [Shoe], _ tallies: [UUID: ShoeMileage.Tally]) -> some View {
        Button { showRetired.toggle() } label: {
            HStack {
                Text("Retired · \(retired.count)")
                    .font(Tokens.Font.ui(13, .medium)).foregroundStyle(Tokens.Palette.textSecondary)
                Spacer()
                Image(systemName: showRetired ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10)).foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        if showRetired {
            ForEach(retired) { shoe in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shoe.name)
                            .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(1)
                        if let day = shoe.retiredAt {
                            Text("Retired \(day.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(Tokens.Font.ui(11)).foregroundStyle(Tokens.Palette.textTertiary)
                        }
                    }
                    Spacer()
                    Text(Self.distanceLabel(tallies[shoe.id]?.miles ?? 0, units))
                        .font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
        }
    }

    private var thresholdRow: some View {
        HStack {
            Text("Nudge to retire at")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            Spacer()
            Menu {
                Picker("Retire at", selection: Binding(get: { threshold }, set: { retirementMiles = $0 })) {
                    ForEach(ShoeMileage.retirementMilesOptions, id: \.self) { Text(wholeUnits(miles: Double($0))).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(wholeUnits(miles: Double(threshold))).font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.accentText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10)).foregroundStyle(Tokens.Palette.accentText)
                }
            }
        }
        .frame(minHeight: 24)
    }

    /// A pair's total, from the miles `ShoeMileage` sums: one decimal under 10, whole above.
    static func distanceLabel(_ miles: Double, _ units: Units) -> String {
        units.formatDistance(miles: miles, decimals: units.distance(miles: miles) < 10 ? 1 : 0)
    }
}

// MARK: - Add sheet

/// A new pair: a name, and the miles already on it if it isn't new.
struct AddShoeSheet: View {
    /// Whether the athlete has no pair in service yet — then the first one starts as the
    /// default, which they can see and switch off.
    let firstPair: Bool
    /// Saves; returns whether it landed.
    let onAdd: (ShoeMileage.Draft, _ makeDefault: Bool) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @State private var name = ""
    @State private var startMiles: Double?
    @State private var makeDefault: Bool
    @State private var saving = false
    @State private var failed = false
    @FocusState private var nameFocused: Bool

    init(firstPair: Bool, onAdd: @escaping (ShoeMileage.Draft, Bool) async -> Bool) {
        self.firstPair = firstPair
        self.onAdd = onAdd
        _makeDefault = State(initialValue: firstPair)
    }

    private var draft: ShoeMileage.Draft? { ShoeMileage.draft(name: name, startMiles: startMiles) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add a pair").display(24)

                    Card {
                        SectionLabel("Name", color: Tokens.Palette.accentText)
                        TextField("e.g. Pegasus 41 — blue", text: $name)
                            .font(Tokens.Font.ui(17))
                            .focused($nameFocused)
                            .submitLabel(.done)
                    }

                    Card {
                        SectionLabel("\(units.name(plural: true).capitalized) already on them")
                        // Typed in the athlete's unit, handed to `ShoeMileage.draft` in miles.
                        TextField("0", value: Binding(
                            get: { startMiles.map { units.distance(miles: $0) } },
                            set: { startMiles = $0.map { units.meters(distance: $0) / Units.metersPerMile } }
                        ), format: .number)
                            .font(Tokens.Font.mono(17))
                            .keyboardType(.decimalPad)
                        Text("Leave blank for a new pair. Runs you tag with it add on from here.")
                            .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
                    }

                    Card {
                        Toggle(isOn: $makeDefault) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Make this my default")
                                    .font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                                Text("Picked for you after a run. You can change it on any run.")
                                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                            }
                        }
                        .tint(Tokens.Palette.voltMark)
                    }

                    if failed {
                        Text("Couldn't save the pair. Check your connection and try again.")
                            .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.danger)
                    }

                    PrimaryButton(title: "Add pair", loading: saving) { Task { await save() } }
                        .disabled(draft == nil)
                        .opacity(draft == nil ? 0.5 : 1)
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
        .onAppear { nameFocused = true }
    }

    private func save() async {
        guard let draft else { return }
        saving = true
        failed = false
        let ok = await onAdd(draft, makeDefault)
        saving = false
        if ok { dismiss() } else { failed = true }
    }
}
