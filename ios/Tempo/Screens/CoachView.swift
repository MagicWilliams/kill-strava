import SwiftUI

struct CoachView: View {
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ForEach(Array(Mock.coach.enumerated()), id: \.offset) { _, msg in
                        bubble(text: msg.0, isUser: msg.1)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            inputBar
        }
        .background(Tokens.Palette.canvas)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(hex: 0x1E2417)).frame(width: 44, height: 44)
                .overlay(Text("C").font(Tokens.Font.display(18)).foregroundStyle(Tokens.Palette.volt))
            VStack(alignment: .leading, spacing: 2) {
                Text("Coach").font(Tokens.Font.display(22)).foregroundStyle(Tokens.Palette.textPrimary)
                Text("Calm expert · always on").font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer()
        }
    }

    private func bubble(text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(text)
                .font(Tokens.Font.ui(15))
                .foregroundStyle(isUser ? Tokens.Palette.onVolt : Tokens.Palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(isUser ? Tokens.Palette.volt : Tokens.Palette.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message your coach…", text: $draft)
                .font(Tokens.Font.ui(15))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Tokens.Palette.surface)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Tokens.Palette.elevated, lineWidth: 1))
            Button { draft = "" } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tokens.Palette.onVolt)
                    .frame(width: 44, height: 44)
                    .background(Tokens.Palette.volt)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Tokens.Palette.inset)
    }
}

#Preview {
    CoachView().preferredColorScheme(.dark)
}
