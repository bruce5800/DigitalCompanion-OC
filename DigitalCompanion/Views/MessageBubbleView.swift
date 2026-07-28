//
//  MessageBubbleView.swift
//  DigitalCompanion
//
//  Created by 李卓伦 on 2026/4/12.
//
//  单条消息气泡 + 头像（iMessage 风格）。与 iPhone 端 MessageBubble 同构，
//  换成 visionOS 的半透明玻璃观感；仍保留原来的 [动画ID] 小字尾签。
//

import SwiftUI
import CompanionCore

struct MessageBubbleView: View {

    let message: ChatMessage
    /// 是否画头像（连续段最后一条才画；由 ChatView 判断）
    var showAvatar: Bool = true

    @Environment(AppModel.self) private var appModel

    private let avatarSize: CGFloat = 32

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                avatarSlot
            } else {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == .user
                            ? Color.blue.opacity(0.8)
                            : Color.white.opacity(0.15)
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if let animName = message.animation {
                    Text("[\(animName)]")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if message.role == .user {
                avatarSlot
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - 头像槽位

    @ViewBuilder
    private var avatarSlot: some View {
        if showAvatar {
            ChatAvatarView(kind: avatarKind, size: avatarSize)
        } else {
            Color.clear.frame(width: avatarSize, height: avatarSize)
        }
    }

    private var avatarKind: ChatAvatarView.Kind {
        switch message.role {
        case .user:
            return .user(
                name: appModel.userPersona.name,
                avatarID: AvatarRegistry.resolvedUserAvatarID(appModel.userPersona.avatarID)
            )
        case .assistant:
            if let persona = appModel.currentPersona {
                return .character(name: persona.name, id: persona.id)
            } else {
                return .character(name: "?", id: "unknown")
            }
        }
    }
}

// MARK: - ChatAvatarView (visionOS)

/// 圆形头像。
/// - 优先从 CompanionCore 的 Resources/Avatars/{id}.jpg 加载图片
/// - 找不到就回退到"首字 + 角色专属颜色"的占位
struct ChatAvatarView: View {

    enum Kind {
        case user(name: String, avatarID: String)
        case character(name: String, id: String)
    }

    let kind: Kind
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let uiImage = loadImage() {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(fallbackColor)
                    .overlay {
                        Text(initial)
                            .font(.system(size: size * 0.5, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    // MARK: - 图片加载

    private var avatarID: String {
        switch kind {
        case .user(_, let avatarID):   return avatarID
        case .character(_, let id):    return id
        }
    }

    private func loadImage() -> UIImage? {
        guard let url = AvatarRegistry.fileURL(for: avatarID) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - 回退占位

    private var initial: String {
        let name: String
        switch kind {
        case .user(let n, _):        name = n
        case .character(let n, _):   name = n
        }
        return String(name.prefix(1))
    }

    private var fallbackColor: Color {
        switch kind {
        case .user:
            return .blue.opacity(0.85)
        case .character(_, let id):
            return personaColor(id)
        }
    }

    private func personaColor(_ id: String) -> Color {
        switch id {
        case "furina":    return Color(red: 0.25, green: 0.55, blue: 0.95)
        case "phainon":   return Color(red: 0.55, green: 0.65, blue: 0.85)
        case "danheng":   return Color(red: 0.50, green: 0.35, blue: 0.75)
        case "sunday":    return Color(red: 0.90, green: 0.75, blue: 0.35)
        case "colunbula": return Color(red: 0.85, green: 0.40, blue: 0.45)
        default:          return .gray
        }
    }
}
