//
//  ChatScreen.swift
//  DigitalCompanionPhone
//
//  主聊天界面：消息列表 + 底部输入栏。
//  iPhone 原生范式：输入栏通过 safeAreaInset 贴在键盘上方。
//

import SwiftUI
import CompanionCore

struct ChatScreen: View {

    @Environment(PhoneAppModel.self) private var appModel
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    let messages = appModel.chatService.messages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        // 时间分隔行（间隔 > 10 分钟或第一条时显示）
                        if let divider = dividerText(at: index, in: messages) {
                            Text(divider)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 6)
                        }
                        MessageBubble(
                            message: message,
                            showAvatar: isLastInRun(at: index, in: messages)
                        )
                        .id(message.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                    }

                    if appModel.chatService.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("思考中…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .id("loading")
                    }

                    if let err = appModel.chatService.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // 多条消息 staggered 出现时的入场动画 —— 配合 ChatService 里的 sleep stagger
                .animation(.spring(response: 0.35, dampingFraction: 0.85),
                           value: appModel.chatService.messages.count)
            }
            .onChange(of: appModel.chatService.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onAppear {
                scrollToBottom(proxy: proxy)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !appModel.isAPIKeyConfigured {
                        noKeyBanner
                    }
                    if let suggestions = currentSuggestions {
                        suggestionsRow(suggestions)
                    }
                    inputBar
                }
                .background(.bar)
            }
            .background(Color(.systemBackground))
        }
    }

    // MARK: - 时间 / 连续段判定

    /// 当前 index 的消息是否要在它上方显示时间分隔行
    private func dividerText(at index: Int, in messages: [ChatMessage]) -> String? {
        let current = messages[index].timestamp
        let previous = index > 0 ? messages[index - 1].timestamp : nil
        return ChatTimestampFormatter.divider(between: previous, and: current)
    }

    /// 当前 index 是否是"同一方连续发消息中的最后一条"。只有它才画头像。
    /// —— 类 iMessage 的紧凑呈现，避免同一方多条消息时头像一堆
    private func isLastInRun(at index: Int, in messages: [ChatMessage]) -> Bool {
        if index == messages.count - 1 { return true }
        return messages[index + 1].role != messages[index].role
    }

    // MARK: - 建议回复行

    /// 只在最新一条 assistant 消息上显示 suggestions；用户一发消息就自动消失
    /// （因为最后一条变成 user message 了）
    private var currentSuggestions: [String]? {
        guard !appModel.chatService.isLoading,
              let last = appModel.chatService.messages.last,
              last.role == .assistant,
              let suggestions = last.suggestions,
              !suggestions.isEmpty
        else { return nil }
        return suggestions
    }

    private func suggestionsRow(_ suggestions: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { text in
                    Button {
                        tapSuggestion(text)
                    } label: {
                        Text(text)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func tapSuggestion(_ text: String) {
        // 与 send() 同理：flush IME composition，再清 inputText
        isInputFocused = false
        inputText = ""
        Task { await appModel.processUserMessage(text) }
    }

    // MARK: - 未配置 API Key 提示条（冷启动：用户关掉设置弹窗后仍能随时找回入口）

    private var noKeyBanner: some View {
        Button {
            appModel.showAPIKeySetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "key.slash.fill")
                Text("还没配 API Key —— 点这里设置就能正常对话")
                    .font(.callout)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("说点什么…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .submitLabel(.send)
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appModel.chatService.isLoading
    }

    // MARK: - 动作

    private func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 先 resign focus：中文输入法点"发送"按钮时 composition 还没提交，
        // 不 resign 的话 inputText = "" 无法清除 IME 里悬停的候选字。
        isInputFocused = false
        inputText = ""
        Task { await appModel.processUserMessage(trimmed) }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if appModel.chatService.isLoading {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = appModel.chatService.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
