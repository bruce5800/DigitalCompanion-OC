//
//  ChatView.swift
//  DigitalCompanion
//
//  Created by 李卓伦 on 2026/4/12.
//

import SwiftUI
import CompanionCore

/// 聊天界面：消息列表 + 输入框
struct ChatView: View {

    @Environment(AppModel.self) private var appModel
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        let messages = appModel.chatService.messages
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if let divider = dividerText(at: index, in: messages) {
                                Text(divider)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 6)
                            }
                            MessageBubbleView(
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
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("思考中...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .id("loading")
                        }

                        // 表演中提示（舞蹈 / 唱歌等，消息会排队）
                        if appModel.performanceService.isPerforming {
                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .font(.caption)
                                Text("正在表演中…消息会在结束后一起发送")
                                    .font(.caption)
                                let queued = appModel.performanceService.queuedMessages.count
                                if queued > 0 {
                                    Text("（已排队 \(queued) 条）")
                                        .font(.caption2)
                                }
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .id("performing")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // 多条消息 staggered 出现时的入场动画（spatial 多数情况只 1 条，仍保持过渡风格一致）
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: appModel.chatService.messages.count)
                }
                .onChange(of: appModel.chatService.messages.count) {
                    withAnimation {
                        if let lastID = appModel.chatService.messages.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }

            // 错误提示
            if let error = appModel.chatService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            // 监听指示：握拳 push-to-talk 期间显示
            if appModel.speechService.isListening {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                    Text("正在听… 松开拳头结束")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            } else if let err = appModel.speechService.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // 建议回复行（只在最新 assistant 消息有 suggestions 时显示）
            if let suggestions = currentSuggestions {
                suggestionsRow(suggestions)
            }

            // 输入栏
            HStack(spacing: 10) {
                let performing = appModel.performanceService.isPerforming
                TextField(performing ? "表演中，消息会排队…" : "说点什么...",
                          text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($isInputFocused)
                    .onSubmit { sendMessage() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: performing ? "tray.and.arrow.down.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || appModel.chatService.isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // 录音期间：实时把识别文本同步到输入框；用户松开后文本留在框内供检查/编辑/发送
        .onChange(of: appModel.speechService.recognizedText) { _, newValue in
            if appModel.speechService.isListening {
                inputText = newValue
            }
        }
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 先 resign focus：中文输入法点"发送"按钮时 composition 还没提交，
        // 不 resign 的话 inputText = "" 无法清除 IME 里悬停的候选字。
        isInputFocused = false
        inputText = ""

        // 表演期间 AppModel 会静默入队；ChatView 这边靠"已排队 N 条"徽标反馈
        // 表演结束后，合并文本作为一条 user 消息正常进入对话
        Task {
            await appModel.processUserMessage(trimmed)
        }
    }

    // MARK: - 时间 / 连续段判定

    private func dividerText(at index: Int, in messages: [ChatMessage]) -> String? {
        let current = messages[index].timestamp
        let previous = index > 0 ? messages[index - 1].timestamp : nil
        return ChatTimestampFormatter.divider(between: previous, and: current)
    }

    private func isLastInRun(at index: Int, in messages: [ChatMessage]) -> Bool {
        if index == messages.count - 1 { return true }
        return messages[index + 1].role != messages[index].role
    }

    // MARK: - 建议回复

    /// 只在最新 assistant 消息有 suggestions、且没在 loading / performing 时显示
    private var currentSuggestions: [String]? {
        guard !appModel.chatService.isLoading,
              !appModel.performanceService.isPerforming,
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
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.12))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func tapSuggestion(_ text: String) {
        isInputFocused = false
        inputText = ""
        Task { await appModel.processUserMessage(text) }
    }
}
