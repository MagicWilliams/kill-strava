import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case today, plan, progress, coach, you
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .plan: return "Plan"
        case .progress: return "Progress"
        case .coach: return "Coach"
        case .you: return "You"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "square.grid.2x2"
        case .plan: return "calendar"
        case .progress: return "chart.bar.fill"
        case .coach: return "bubble.left.fill"
        case .you: return "person.fill"
        }
    }
}

struct RootTabView: View {
    @State private var selection: Tab = .today

    var body: some View {
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    TempoTabBar(selection: $selection)
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .today:    TodayView()
        case .plan:     PlanView()
        case .progress: ProgressScreen()
        case .coach:    CoachView()
        case .you:      YouView()
        }
    }
}

struct TempoTabBar: View {
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                let active = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: active ? .semibold : .regular))
                        Text(tab.title)
                            .font(Tokens.Font.ui(10, active ? .semibold : .medium))
                    }
                    .foregroundStyle(active ? Tokens.Palette.volt : Tokens.Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .background(Tokens.Palette.inset)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Palette.elevated).frame(height: 1)
        }
    }
}

#Preview {
    RootTabView().preferredColorScheme(.dark)
}
