import SwiftUI

/// "What changed": every write the coach has actually made, newest first (#88).
///
/// The entries come from `Engine/ChangeLedger`; this screen only lays them out and routes the
/// two links each one carries — to the thing it touched, and back to the chat message that
/// proposed it.
struct ChangesView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    private enum Load: Equatable { case loading, loaded, failed }

    @State private var entries: [ChangeLedger.Entry] = []
    @State private var load: Load = .loading
    @State private var kind: ChangeLedger.Kind?   // nil = All

    var body: some View {
        ZStack(alignment: .topLeading) {
            Tokens.Palette.canvas.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    filterRow
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .refreshable { await reload() }

            backButton
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await reload() }
    }

    private func reload() async {
        do {
            entries = try await ChangeLedgerService.load()
            load = .loaded
        } catch {
            Telemetry.error("ledger.unreadable", error)
            // Keep whatever is already on screen; only an empty screen becomes the error.
            if entries.isEmpty { load = .failed }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("What changed").display(30)
            Text("Everything the coach has actually changed, newest first.")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
        .padding(.top, 56)   // clears the floating back button
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            chip("All", active: kind == nil) { kind = nil }
            ForEach(ChangeLedger.Kind.allCases) { k in
                chip(k.label, active: kind == k) { kind = k }
            }
            Spacer()
        }
    }

    private func chip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Tokens.Font.ui(12, active ? .semibold : .medium))
                .foregroundStyle(active ? Tokens.Palette.onVolt : Tokens.Palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(active ? Tokens.Palette.volt : Tokens.Palette.surface)
                .clipShape(Capsule())
        }
        .buttonStyle(Pressable())
    }

    @ViewBuilder private var content: some View {
        switch load {
        case .loading:
            ProgressView().tint(Tokens.Palette.textTertiary)
                .frame(maxWidth: .infinity).padding(.top, 24)
        case .failed:
            note("Couldn't reach the server, so the ledger can't be read right now. Pull to refresh.")
        case .loaded:
            let visible = ChangeLedger.filtered(entries, kind: kind)
            if visible.isEmpty {
                note(kind == nil
                     ? "Nothing yet. When you confirm a change the coach proposes, it shows up here."
                     : "No \(kind!.label.lowercased()) changes yet.")
            } else {
                let groups = ChangeLedger.grouped(visible, now: .now, calendar: RunStore.cal)
                section("This week", groups.thisWeek)
                section("Earlier", groups.earlier)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [ChangeLedger.Entry]) -> some View {
        if !items.isEmpty {
            SectionLabel(title).padding(.top, 6)
            ForEach(items) { entryCard($0) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            .padding(.top, 12)
    }

    private func entryCard(_ entry: ChangeLedger.Entry) -> some View {
        Card(padding: 14) {
            HStack {
                SectionLabel(entry.kind.label, color: Tokens.Palette.accentText)
                Spacer()
                Text(entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(Tokens.Font.mono(10)).foregroundStyle(Tokens.Palette.textTertiary)
            }
            Text(entry.title)
                .font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
            if entry.changes.isEmpty {
                Text(entry.summary)
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            } else {
                Text(entry.beforeAfter)
                    .font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(4)
            }
            if let why = entry.why {
                Text(why)
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(4)
            }
            HStack(spacing: 8) {
                targetLink(entry.target)
                linkButton("See in chat", symbol: "bubble.left") { router.showCoachMessage(entry.id) }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private func targetLink(_ target: ChangeLedger.Target) -> some View {
        switch target {
        case .run, .loggedRun:
            if let run = ChangeLedger.run(for: target, in: store.runs) {
                linkButton("Open run", symbol: "figure.run") { router.openRun(run) }
            } else {
                // Superseded as a duplicate, or not loaded yet — say so instead of guessing.
                Text("Run not in your log")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
            }
        case .session, .plan:
            linkButton("Open plan", symbol: "calendar") { router.show(.plan) }
        case .profile:
            linkButton("Open You", symbol: "person") { router.show(.you) }
        case .unlinked:
            EmptyView()
        }
    }

    private func linkButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Tokens.Font.ui(12, .semibold))
                .foregroundStyle(Tokens.Palette.accentText)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Tokens.Palette.surface)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Tokens.Palette.elevated, lineWidth: 1))
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
    ChangesView()
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
        .preferredColorScheme(.dark)
}
