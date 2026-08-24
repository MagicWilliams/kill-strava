import SwiftUI

struct CoachView: View {
    var onboarding = false

    @EnvironmentObject private var store: RunStore
    @StateObject private var chat = ChatStore()
    @State private var draft = ""

    /// iMessage-style drag-from-the-right to reveal per-message timestamps.
    @GestureState private var timeReveal: CGFloat = 0

    /// Context-aware suggestions: inferred from today's session state, this week's
    /// misses, the projection, and how long it's been since the last conversation.
    private var quickReplies: [String] {
        guard store.plan != nil else {
            return ["Assess me and propose a goal", "How's my week looking?", "Analyze my last run"]
        }
        var suggestions: [String] = []

        // Stale conversation → lead with the general check-in.
        let lastTalked = chat.messages.last?.timestamp ?? .distantPast
        if Date.now.timeIntervalSince(lastTalked) > 3 * 86_400 {
            suggestions.append("How's my week looking?")
        }

        if let session = store.todaySession {
            if session.status == "done" {
                suggestions.append("Break down today's run")
                suggestions.append("What's the focus tomorrow?")
            } else if (session.isQuality || session.type == "long"), store.todayCheckIn == nil {
                suggestions.append("What's today's session for?")
                suggestions.append("Something feels off today")
            } else {
                suggestions.append("What's today's session for?")
            }
        } else {
            suggestions.append("How should I use this rest day?")
        }

        let today = PlanDates.todayString
        if store.sessions.contains(where: { $0.status == "planned" && $0.date < today && $0.type != "rest" }) {
            suggestions.append("I missed a session — what now?")
        }

        if let projected = store.plan?.projected_finish_s,
           let goal = store.goal?.goalTimeSeconds, projected > goal {
            suggestions.append("How do we close the gap?")
        } else {
            suggestions.append("Am I on track?")
        }

        var seen = Set<String>()
        return suggestions.filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, msg in
                            if index == 0 || !Calendar.current.isDate(msg.timestamp, inSameDayAs: chat.messages[index - 1].timestamp) {
                                daySeparator(msg.timestamp)
                            }
                            messageRow(msg)
                                .id(msg.id)
                        }
                        if chat.isThinking { thinking.id("thinking") }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .updating($timeReveal) { value, state, _ in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            state = max(min(value.translation.width, 0), -64)
                        }
                )
                .animation(.spring(duration: 0.3), value: timeReveal)
                .onChange(of: chat.messages) { _, msgs in
                    if let last = msgs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: chat.isThinking) { _, thinking in
                    if thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }
            if let error = chat.errorText {
                Text(error)
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.danger)
                    .padding(.horizontal, 20).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !chat.isThinking && !chat.messages.isEmpty && !onboarding {
                quickReplyRow
            }
            inputBar
        }
        .background(Tokens.Palette.canvas)
        .task {
            chat.onboardingMode = onboarding
            chat.runStore = store
            await chat.load(context: store.coachContext(onboarding: onboarding))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(hex: 0x1E2417)).frame(width: 44, height: 44)
                .overlay(Text("C").font(Tokens.Font.display(18)).foregroundStyle(Tokens.Palette.volt))
            VStack(alignment: .leading, spacing: 2) {
                Text("Coach").font(Tokens.Font.display(22)).foregroundStyle(Tokens.Palette.textPrimary)
                Text(onboarding ? "Setup interview · a few questions" : "Calm expert · sees your real runs")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    /// Bubble + optional action card, sliding left on drag to reveal the timestamp.
    private func messageRow(_ msg: ChatMessage) -> some View {
        let progress = Double(min(-timeReveal / 64, 1))
        return ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                bubble(text: msg.text, isUser: msg.role == .user)
                if let action = msg.action {
                    actionCard(for: msg.id, action: action, state: msg.actionState)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: timeReveal)

            Text(msg.timestamp, format: .dateTime.hour().minute())
                .font(Tokens.Font.mono(10))
                .foregroundStyle(Tokens.Palette.textTertiary)
                .fixedSize()
                .opacity(progress)
                .offset(x: 44 * (1 - progress))
                .allowsHitTesting(false)
        }
    }

    private func daySeparator(_ date: Date) -> some View {
        Text(dayLabel(date))
            .font(Tokens.Font.mono(10)).tracking(1.2)
            .foregroundStyle(Tokens.Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "TODAY" }
        if Calendar.current.isDateInYesterday(date) { return "YESTERDAY" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
    }

    private func bubble(text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(.init(text))   // renders markdown emphasis if the coach uses it
                .font(Tokens.Font.ui(15))
                .lineSpacing(3)
                .foregroundStyle(isUser ? Tokens.Palette.onVolt : Tokens.Palette.textPrimary)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(isUser ? Tokens.Palette.volt : Tokens.Palette.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    /// Confirm card for a coach-proposed change. Walks pending → applying → applied/failed,
    /// and stays on screen after resolving as evidence the change actually landed.
    private func actionCard(for messageID: UUID, action: ProposedAction, state: ChatMessage.ActionState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(actionTitle(action.type), color: borderColor(for: state))
            Text(action.displaySummary)
                .font(Tokens.Font.ui(14, .medium))
                .foregroundStyle(state == .dismissed ? Tokens.Palette.textTertiary : Tokens.Palette.textPrimary)

            switch state {
            case .pending, .failed:
                if state == .failed {
                    Text("That didn't go through — Confirm to retry.")
                        .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.danger)
                }
                HStack(spacing: 8) {
                    Button {
                        Task { _ = await chat.confirm(messageID, runStore: store) }
                    } label: {
                        Text(state == .failed ? "Retry" : "Confirm")
                            .font(Tokens.Font.ui(14, .bold))
                            .foregroundStyle(Tokens.Palette.onVolt)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Tokens.Palette.volt)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(Pressable())
                    Button {
                        chat.dismiss(messageID)
                    } label: {
                        Text("Dismiss")
                            .font(Tokens.Font.ui(14, .medium))
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Tokens.Palette.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(Tokens.Palette.elevated, lineWidth: 1))
                    }
                    .buttonStyle(Pressable())
                }
            case .applying:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Tokens.Palette.volt)
                    Text(chat.busyLabel ?? "Applying…")
                        .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            case .applied:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.Palette.success)
                    Text("Applied").font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.success)
                }
            case .dismissed:
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle").foregroundStyle(Tokens.Palette.textTertiary)
                    Text("Dismissed").font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor(for: state).opacity(0.4), lineWidth: 1)
        )
        .padding(.trailing, 40)
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private func borderColor(for state: ChatMessage.ActionState) -> Color {
        switch state {
        case .applied: return Tokens.Palette.success
        case .failed: return Tokens.Palette.danger
        case .dismissed: return Tokens.Palette.textTertiary
        default: return Tokens.Palette.volt
        }
    }

    private func actionTitle(_ type: String) -> String {
        switch type {
        case "amend_run": return "Edit run"
        case "add_run": return "Log run"
        case "set_risk_tolerance": return "Training mode"
        default: return "Proposed change"
        }
    }

    private var thinking: some View {
        HStack(spacing: 10) {
            TypingDots()
            Text(chat.busyLabel ?? "Coach is thinking…")
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Tokens.Palette.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity)
    }

    private var quickReplyRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(quickReplies, id: \.self) { reply in
                    Button {
                        Task { await chat.send(reply, context: store.coachContext(onboarding: onboarding)) }
                    } label: {
                        Text(reply)
                            .font(Tokens.Font.ui(13, .medium))
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Tokens.Palette.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(Tokens.Palette.elevated, lineWidth: 1))
                    }
                    .buttonStyle(Pressable())
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message your coach…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(Tokens.Font.ui(15))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Tokens.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Tokens.Palette.elevated, lineWidth: 1))
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tokens.Palette.onVolt)
                    .frame(width: 44, height: 44)
                    .background(chat.isThinking ? Tokens.Palette.elevated : Tokens.Palette.volt)
                    .clipShape(Circle())
            }
            .buttonStyle(Pressable())
            .disabled(chat.isThinking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Tokens.Palette.inset)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        Task { await chat.send(text, context: store.coachContext(onboarding: onboarding)) }
    }
}

/// Staggered pulse — unmistakably "alive" while the coach works.
struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Tokens.Palette.volt)
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1.0 : 0.55)
                    .opacity(animating ? 1.0 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

#Preview {
    CoachView().environmentObject(RunStore()).preferredColorScheme(.dark)
}
