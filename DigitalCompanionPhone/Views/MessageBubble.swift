//
//  MessageBubble.swift
//  DigitalCompanionPhone
//
//  单条消息气泡 + 头像。iMessage 风格：
//  - 用户右对齐蓝色气泡、右侧头像
//  - assistant 左对齐灰色气泡、左侧头像
//  - 同一方连续多条消息时，只在"这个连续段的最后一条"显示头像（avatarless 占位保持对齐）
//

import SwiftUI
import CompanionCore

struct MessageBubble: View {

    let message: ChatMessage
    /// 是否渲染头像。ChatScreen 判断"是否连续段最后一条"后传入；
    /// 中间消息传 false，位置用透明占位保留
    let showAvatar: Bool

    @Environment(PhoneAppModel.self) private var appModel

    private let avatarSize: CGFloat = 32

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                avatarSlot
            } else {
                Spacer(minLength: 40)
            }

            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleColor)
                .foregroundStyle(foregroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if message.role == .user {
                avatarSlot
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - 头像槽位（头像本身 or 占位）

    @ViewBuilder
    private var avatarSlot: some View {
        if showAvatar {
            ChatAvatar(kind: avatarKind, size: avatarSize)
        } else {
            Color.clear.frame(width: avatarSize, height: avatarSize)
        }
    }

    private var avatarKind: ChatAvatar.Kind {
        switch message.role {
        case .user:
            return .user(name: appModel.userPersona.name)
        case .assistant:
            if let persona = appModel.currentPersona {
                return .character(name: persona.name, id: persona.id)
            } else {
                return .character(name: "?", id: "unknown")
            }
        }
    }

    // MARK: - 气泡配色

    private var bubbleColor: Color {
        switch message.role {
        case .user:      return .accentColor
        case .assistant: return Color(.secondarySystemBackground)
        }
    }

    private var foregroundColor: Color {
        switch message.role {
        case .user:      return .white
        case .assistant: return .primary
        }
    }
}

// MARK: - ChatAvatar

/// 圆形头像。
/// - 优先从 CompanionCore 的 Resources/Avatars/{id}.jpg 加载图片
/// - 找不到就回退到"首字 + 角色专属颜色"的占位
struct ChatAvatar: View {

    enum Kind {
        case user(name: String)
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
        case .user:                    return AvatarRegistry.userAvatarID
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
        case .user(let n):           name = n
        case .character(let n, _):   name = n
        }
        return String(name.prefix(1))
    }

    private var fallbackColor: Color {
        switch kind {
        case .user:
            return .accentColor
        case .character(_, let id):
            return personaColor(id)
        }
    }

    /// 角色 → 标识色映射（仅占位时用；有图片就走不到这里）
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
