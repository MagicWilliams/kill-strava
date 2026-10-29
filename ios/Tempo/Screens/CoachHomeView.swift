import SwiftUI

/// Coach home: the conversations you have had, newest first, and a way to start a new one
/// (#87, mockup screen 1).
///
/// The Coach tab used to open straight into one endless transcript. Nothing was findable and
/// nothing ever ended — and because the coach only ever sees the last 24 messages, the parts
/// that scrolled away were gone to it as well. This screen is the other half of that fix: a
/// thread has a title, a recap and the changes it made, so last Tuesday's pacing decision is
/// one tap away instead of a thousand lines up.
///
/// Every judgement here comes from `Engine/CoachThreads`: list order, what a thread with no
/// recap yet is allowed to claim, which threads are owed a write-up. This screen lays them
/// out and routes the taps.
struct CoachHomeView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter

    private enum Load: Equatable { case loading, loaded, failed }

    @State private var threads: [CoachThreads.Row] = []
    @State private var tags: [UUID: [CoachThreads.Tag]] = [:]
    /// Changes applied this week, for the "What changed" row. Nil until the ledger answers.
    @State private var changesThisWeek: Int?
    @State private var load: Load = .loading
    @State private var starting = false
    /// What this screen has already opened a conversation for, so popping back to the list
    /// cannot bounce the athlete straight into a thread again. A focus `CoachView` could not
    /// find — a message older than the page it loaded — stays set, and without this the pop
    /// would re-push it forever.
    @State private var routed: Set<UUID> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header
                changesRow
                SectionLabel("Conversations").padding(.top, 6)
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.Palette.canvas)
        .scrollIndicators(.hidden)
        .refreshable { await reload() }
        // Every appearance, not once: a thread the athlete just left is owed a recap, and
        // coming back here is the moment that recap can be written and shown.
        .task { await reload() }
        // Coming back from a thread leaves this screen alive underneath the pop, so no
        // `.task` fires — the same reason the ledger row never refreshed on the old Coach
        // tab. The recap the thread just earned is the whole point of looking again.
        .onChange(of: router.path.count) { _, count in
            guard count == 0 else { return }
            Task { await reload() }
        }
        .onChange(of: router.coachFocus) { _, _ in openConversationIfNeeded() }
        // An intake sent while this screen was already up — the form is presented over it.
        .onChange(of: store.intakeHandoff?.id) { _, _ in openConversationIfNeeded() }
    }

    // MARK: - Loading

    private func reload() async {
        do {
            let rows = try await CoachThreadService.threads()
            threads = rows
            load = .loaded
            // Either may have arrived with the tab switch, before this view existed, so
            // both are checked here as well as on change.
            openConversationIfNeeded()
            if let applied = try? await CoachThreadService.applied() {
                tags = CoachThreadService.tags(from: applied)
                changesThisWeek = ChangeLedger.countThisWeek(
                    ChangeLedger.entries(from: applied.map(\.record)),
                    now: .now,
                    calendar: RunStore.cal
                )
            }
            // The write-ups come last and on their own: each is a model round trip, and the
            // list must be on screen before them. A thread that gains a recap here shows it
            // on the next appearance — or on a pull to refresh, if the athlete is watching.
            if await CoachThreadService.summarizePending(rows, context: store.coachContext()) {
                threads = (try? await CoachThreadService.threads()) ?? rows
            }
        } catch {
            Telemetry.error("coach.threads_unreadable", error)
            // Keep whatever is already on screen; only an empty screen becomes the error.
            if threads.isEmpty { load = .failed }
        }
    }

    /// Open a conversation when something outside the list needs one.
    ///
    /// Two callers, both of which used to land on a tab that *was* the transcript:
    ///
    ///  - **"See in chat"** from What changed (#88). The ledger doesn't know which thread
    ///    holds a message, so the live conversation is the honest guess and the transcript
    ///    scrolls to the message if it is in the page it loads.
    ///  - **A just-sent training intake** (#102), whose first turn is the athlete's answers.
    ///    Those have to reach the coach, and `ChatStore.load` is what sends them — so a
    ///    conversation has to be open for it to happen at all.
    ///
    /// A live thread is reused; with none, the intake gets a new one, because answers with
    /// nowhere to go is the failure this guards.
    private func openConversationIfNeeded() {
        guard router.path.isEmpty, load == .loaded else { return }
        let focus = router.coachFocus
        let intake = store.intakeHandoff?.sentToCoach == false ? store.intakeHandoff?.id : nil
        let reasons = [focus, intake].compactMap { $0 }.filter { !routed.contains($0) }
        guard !reasons.isEmpty else { return }
        routed.formUnion(reasons)
        if let live = CoachThreads.active(in: threads, now: .now) {
            router.openCoachThread(live.id)
        } else {
            startNewChat()
        }
    }

    /// Start a new conversation and open it.
    ///
    /// The thread is created before the push so the transcript it opens on is scoped from
    /// its first message — a chat that starts unscoped writes rows no thread can see.
    ///
    /// The write-up of the conversation being left is awaited here rather than backgrounded,
    /// and the order is the reason: a thread is owed a recap once a *newer* one exists, so
    /// the new thread has to be created first, and the recap has to be written before the
    /// push because it is what the new conversation opens with — on screen as "Picking up
    /// from", and in the coach's own context as `memory.picking_up`. Pushing first would
    /// send the opening turn to a coach that had not been told what the last conversation
    /// settled. It is one model round trip, bounded by `Supa`'s 15s request timeout, and the
    /// button says it is working.
    private func startNewChat() {
        guard !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                let id = try await CoachThreadService.create()
                let rows = (try? await CoachThreadService.threads()) ?? []
                if !rows.isEmpty { threads = rows }
                await CoachThreadService.summarizePending(rows, context: store.coachContext())
                router.openCoachThread(id)
            } catch {
                Telemetry.error("coach.thread_create_failed", error)
                load = threads.isEmpty ? .failed : load
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Coach").display(30)
                Text("Calm expert · sees your real runs")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer()
            newChatButton
        }
        .padding(.top, 8)
    }

    private var newChatButton: some View {
        Button(action: startNewChat) {
            HStack(spacing: 6) {
                if starting {
                    ProgressView().controlSize(.small).tint(Tokens.Palette.textTertiary)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                }
                Text(starting ? "Starting\u{2026}" : "New chat").font(Tokens.Font.ui(14, .semibold))
            }
            .foregroundStyle(starting ? Tokens.Palette.textSecondary : Tokens.Palette.onVolt)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(starting ? Tokens.Palette.elevated : Tokens.Palette.volt)
            .clipShape(Capsule())
        }
        .buttonStyle(Pressable())
        .disabled(starting)
    }

    /// Entry point to the ledger of applied changes (#88), moved here from the transcript
    /// when Coach home became a screen of its own.
    private var changesRow: some View {
        Button { router.openChanges() } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Tokens.Palette.accentText)
                Text("What changed")
                    .font(Tokens.Font.ui(14, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                Spacer()
                if let count = changesThisWeek {
                    Text(count == 0 ? "None this week" : "\(count) this week")
                        .font(Tokens.Font.mono(11)).foregroundStyle(Tokens.Palette.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Tokens.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }

    @ViewBuilder private var content: some View {
        switch load {
        case .loading:
            ProgressView().tint(Tokens.Palette.textTertiary)
                .frame(maxWidth: .infinity).padding(.top, 24)
        case .failed:
            note("Couldn't reach the server, so your conversations can't be read right now. Pull to refresh.")
        case .loaded:
            if threads.isEmpty {
                note("No conversations yet. Tap New chat and the coach will open with a read on your training.")
            } else {
                let live = CoachThreads.active(in: threads, now: .now)?.id
                ForEach(threads) { thread in
                    threadCard(thread, isActive: thread.id == live)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            .padding(.top, 4)
    }

    private func threadCard(_ thread: CoachThreads.Row, isActive: Bool) -> some View {
        Button { router.openCoachThread(thread.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(CoachThreads.displayTitle(thread))
                        .font(Tokens.Font.ui(16, .semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Text(dayLabel(thread.lastMessageAt))
                        .font(Tokens.Font.mono(10))
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .fixedSize()
                }
                Text(CoachThreads.recap(thread, isActive: isActive))
                    .font(Tokens.Font.ui(14))
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let threadTags = tags[thread.id], !threadTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(threadTags) { tag in
                            Tag(text: tag.label, fg: tagColor(tag.kind), bg: Tokens.Palette.elevated)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }

    /// The kinds the ledger filters by, in the ledger's own colours, so a "Plan" pill here
    /// and a "Plan" entry there read as the same thing.
    private func tagColor(_ kind: ChangeLedger.Kind) -> Color {
        switch kind {
        case .plan: return Tokens.Palette.accentText
        case .runs: return Tokens.Palette.info
        case .body: return Tokens.Palette.warning
        case .you:  return Tokens.Palette.textSecondary
        }
    }

    /// Same vocabulary as the transcript's day separators: today and yesterday are named,
    /// anything older is dated.
    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "TODAY" }
        if Calendar.current.isDateInYesterday(date) { return "YESTERDAY" }
        return date.formatted(.dateTime.month(.abbreviated).day()).uppercased()
    }
}

#Preview {
    CoachHomeView()
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
        .preferredColorScheme(.dark)
}
