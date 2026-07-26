//
//  FactEditSheet.swift
//  DigitalCompanionPhone
//
//  编辑单条 UserFact 的 sheet。tap 一条 fact → 弹出 → 改 content / category → 保存。
//  调试用神器：改一条 fact，下一轮 LLM 回复就能看到记忆变化的影响。
//

import SwiftUI
import CompanionCore

struct FactEditSheet: View {

    let fact: UserFact
    /// 保存按钮回调；调用方负责更新 MemorySnapshot 并落盘
    let onSave: (UserFact) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var content: String = ""
    @State private var category: UserFact.Category = .userInfo

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    Picker("分类", selection: $category) {
                        ForEach(UserFact.Category.allCases, id: \.self) { cat in
                            Text(cat.displayName).tag(cat)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField("自然语言短句", text: $content, axis: .vertical)
                        .lineLimit(2...8)
                } header: {
                    Text("内容")
                } footer: {
                    Text("写成完整句子，例：「用户养了一只白猫，叫花花」。下次 LLM 调用时这条事实会进 system prompt。")
                }

                Section("元信息") {
                    LabeledContent("ID") {
                        Text(fact.id.uuidString.prefix(8))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    LabeledContent("置信度") {
                        Text(String(format: "%.2f", fact.confidence))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    LabeledContent("首次观察") {
                        Text(ChatTimestampFormatter.format(fact.firstObserved))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("编辑 Fact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        save()
                    }
                    .bold()
                    .disabled(!canSave)
                }
            }
            .onAppear {
                content = fact.content
                category = fact.category
            }
        }
    }

    private var canSave: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != fact.content || category != fact.category
    }

    private func save() {
        var updated = fact
        updated.category = category
        updated.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.lastConfirmed = Date()
        onSave(updated)
        dismiss()
    }
}
