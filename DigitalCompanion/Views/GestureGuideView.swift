//
//  GestureGuideView.swift
//  DigitalCompanion
//
//  手势引导：告诉用户在沉浸空间里能用哪些右手手势跟角色互动。
//  首次进入沉浸空间时自动弹一次（ContentView 用 @AppStorage 记住），
//  之后可从顶部"手势"按钮随时再看。手势效果对应 TrackingService + ImmersiveView.handleGesture。
//

import SwiftUI

struct GestureGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private let items: [Item] = [
        .init(icon: "mic.fill",
              title: "握拳按住 · 说话",
              detail: "右手握拳并保持，对着她说话；松开结束。这是和她语音对话的方式。"),
        .init(icon: "hand.wave.fill",
              title: "挥手 · 叫她过来",
              detail: "抬起右手挥一挥，她会走到你面前。"),
        .init(icon: "hand.raised.fill",
              title: "手掌前推 · 让她后退",
              detail: "手掌张开朝前推，她会退后给你留出空间。"),
        .init(icon: "hand.thumbsup.fill",
              title: "竖大拇指 · 夸夸她",
              detail: "对她竖起大拇指，她会害羞地回应你。"),
        .init(icon: "hand.raised.fingers.spread.fill",
              title: "张开手掌 · 打个招呼",
              detail: "张开手掌朝向她，她会挥手回应。"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("手势互动", systemImage: "hand.point.up.left.fill")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("知道了") { dismiss() }
            }
            .padding(.bottom, 6)

            Text("打开沉浸空间后，用右手手势就能和她互动：")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)

            ForEach(items) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.icon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 34, alignment: .center)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(item.title))
                            .font(.headline)
                        Text(LocalizedStringKey(item.detail))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                if item.id != items.last?.id {
                    Divider()
                }
            }

        }
        .padding(26)
        .frame(maxWidth: 540)
    }
}

#Preview {
    GestureGuideView()
}
