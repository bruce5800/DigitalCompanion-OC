//
//  PersonaMemoryDetailScreen.swift
//  DigitalCompanionPhone
//
//  单角色记忆详情页 —— Memory Inspector 点进来后看到的页面。
//  展示：
//    - 头像 + 名字 + 快照元数据（消息数 / 最后活跃）
//    - Rolling summary（滚动摘要，长对话中被压缩的旧历史）
//    - 最新一轮 LLM suggestions（验证持久化 + 看 LLM 生成质量）
//    - [A1 步骤 1] Facts / Episodes / Bond 三个区块（现阶段占位，步骤 2 后会填入）
//    - 完整消息历史（紧凑 transcript 样式，带时间戳）
//    - 删除此角色记录
//
//  注：这里故意不复用 MessageBubble —— 调试场景要看更多原始信息（时间戳、animation、
//  suggestions 等），比气泡那种"展示型"密度更高。
//

import SwiftUI
import CompanionCore

struct PersonaMemoryDetailScreen: View {

    let snapshot: ChatSnapshot

    @Environment(PhoneAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var confirmDelete = false

    // A1：加载 memory snapshot
    @State private var memorySnapshot: MemorySnapshot?
    @State private var memoryLoaded = false
    @State private var reflecting = false      // 手动触发反思中
    @State private var editingFact: UserFact?  // tap fact 行 → 唤起 FactEditSheet

    var body: some View {
        List {
            // 头部：头像 + 元信息
            Section {
                HStack(spacing: 14) {
                    ChatAvatar(
                        kind: .character(name: personaName, id: snapshot.personaID),
                        size: 52
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(personaName))
                            .font(.title3.bold())
                        HStack(spacing: 6) {
                            Text(isEnglish ? "\(snapshot.messages.count) messages" : "\(snapshot.messages.count) 条")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.tertiary)
                            Text(ChatTimestampFormatter.format(snapshot.lastModified))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // 最新 LLM suggestions（如果最后一条是 assistant 且有 suggestions）
            if let latest = snapshot.messages.last,
               latest.role == .assistant,
               let suggestions = latest.suggestions,
               !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.self) { s in
                        Text(s)
                            .font(.callout)
                    }
                } header: {
                    Text("建议回复")
                }
            }

            // A1：三层记忆 + 手动反思按钮（仅当前角色）
            factsSection
            episodesSection
            bondSection
            if isCurrentPersona {
                reflectionDebugSection
            }

            // 消息历史（compact transcript）
            if !snapshot.messages.isEmpty {
                Section("消息历史") {
                    ForEach(snapshot.messages) { msg in
                        messageRow(msg)
                    }
                }
            }

            // 危险区
            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("删除此角色的记录", systemImage: "trash")
                }
            } footer: {
                Text(deleteFooterText)
            }
        }
        .navigationTitle(Text(LocalizedStringKey(personaName)))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            isEnglish ? "Delete \(personaName)'s history?" : "删除 \(personaName) 的记录？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("确定删除", role: .destructive) {
                Task {
                    await appModel.deletePersonaHistory(snapshot.personaID)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(isEnglish
                 ? "This deletes \(snapshot.messages.count) messages and their memory summary. \(isCurrentPersona ? "The current chat will restart." : "")"
                 : "会删除 \(snapshot.messages.count) 条对话历史和记忆摘要。\(isCurrentPersona ? "当前正在聊，删除后会重新发开场白。" : "")")
        }
        .task { await loadMemory() }
        .sheet(item: $editingFact) { fact in
            FactEditSheet(fact: fact) { updated in
                Task { await applyFactUpdate(updated) }
            }
        }
    }

    // MARK: - A1 记忆三层（步骤 3：可编辑 / 删除）

    @ViewBuilder
    private var factsSection: some View {
        Section {
            if !memoryLoaded {
                Text("加载中…").foregroundStyle(.secondary)
            } else if let facts = memorySnapshot?.facts, !facts.isEmpty {
                ForEach(UserFact.Category.allCases, id: \.self) { category in
                    let inCategory = facts.filter { $0.category == category }
                    if !inCategory.isEmpty {
                        factCategoryHeader(category)
                        ForEach(inCategory) { fact in
                            factRow(fact)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await deleteFact(fact.id) }
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            } else {
                Text("暂无")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于你")
        } footer: {
            Text("伙伴会在相处中慢慢了解你。点一条可编辑，左滑可删除。")
        }
    }

    @ViewBuilder
    private func factCategoryHeader(_ category: UserFact.Category) -> some View {
        Text(LocalizedStringKey(category.displayName))
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func factRow(_ fact: UserFact) -> some View {
        Button {
            editingFact = fact
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text("·")
                Text(fact.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var episodesSection: some View {
        Section {
            if !memoryLoaded {
                Text("加载中…").foregroundStyle(.secondary)
            } else if let episodes = memorySnapshot?.episodes, !episodes.isEmpty {
                // 按时间倒序：最新的在上（Inspector 视角）
                let sorted = episodes.sorted { $0.startDate > $1.startDate }
                ForEach(sorted) { ep in
                    episodeRow(ep)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await deleteEpisode(ep.id) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } else {
                Text("暂无")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("共同经历")
        } footer: {
            Text("你们一起经历过的片段，最新的在上。")
        }
    }

    @ViewBuilder
    private func episodeRow(_ ep: Episode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ep.title).font(.callout.bold())
                Spacer()
                Text(episodeDateLabel(ep.startDate))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(ep.summary)
                .font(.caption)
                .textSelection(.enabled)
            if !ep.keywords.isEmpty {
                Text(ep.keywords.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let tone = ep.emotionalTone, !tone.isEmpty {
                Label(tone, systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func episodeDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let df = DateFormatter()
        df.locale = locale
        if calendar.isDateInToday(date) { return isEnglish ? "Today" : "今天" }
        if calendar.isDateInYesterday(date) { return isEnglish ? "Yesterday" : "昨天" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            df.dateFormat = isEnglish ? "MMM d" : "M月d日"
        } else {
            df.dateFormat = isEnglish ? "MMM d, yyyy" : "yyyy年M月d日"
        }
        return df.string(from: date)
    }

    /// "立即触发反思"按钮 —— 仅当前角色可见。
    /// 反思在后台跑，完成后自动重新加载 memory snapshot。
    @ViewBuilder
    private var reflectionDebugSection: some View {
        Section {
            Button {
                Task { await runManualReflection() }
            } label: {
                HStack {
                    if reflecting {
                        ProgressView().controlSize(.small)
                        Text("反思中…")
                    } else {
                        Label("立即触发反思", systemImage: "sparkles")
                    }
                    Spacer()
                    Text("turns: \(appModel.chatService.assistantTurnsSinceReflection) / \(appModel.chatService.reflectionThreshold)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .disabled(reflecting)
        } header: {
            Text("Debug")
        } footer: {
            Text(isEnglish
                 ? "Reflect now using the last \(appModel.chatService.reflectionChunkSize) messages. Memory below will refresh afterward."
                 : "不等阈值，立即用最近 \(appModel.chatService.reflectionChunkSize) 条消息跑一次反思。完成后下方记忆会刷新。")
        }
    }

    @ViewBuilder
    private var bondSection: some View {
        Section {
            if !memoryLoaded {
                Text("加载中…").foregroundStyle(.secondary)
            } else if let bond = memorySnapshot?.bond {

                // 亲密度可视化
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("亲密度")
                            .font(.subheadline)
                        Spacer()
                        Text("\(bond.affection) / 100")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(bond.affection), total: 100)
                        .tint(.pink)
                    Text(LocalizedStringKey(bond.affectionLevelLabel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                // 近期情绪
                if let mood = bond.recentMood, !mood.isEmpty {
                    LabeledContent {
                        Text(mood).foregroundStyle(.secondary)
                    } label: {
                        Label("近期情绪", systemImage: "waveform.path.ecg")
                    }
                }

                // 未兑现承诺（每条可左滑删）
                ForEach(bond.pendingCommitments) { commitment in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(commitment.description, systemImage: "checkmark.circle")
                            .font(.callout)
                        HStack(spacing: 8) {
                            Text(isEnglish
                                 ? "Promised on \(commitmentDateLabel(commitment.createdAt))"
                                 : "承诺于 \(commitmentDateLabel(commitment.createdAt))")
                            // A4：dueAt 存在就显示触发时间状态
                            if let dueAt = commitment.dueAt {
                                Text("·").foregroundStyle(.tertiary)
                                Text(commitmentDueLabel(dueAt: dueAt))
                                    .foregroundStyle(dueAt <= Date() ? .orange : .secondary)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 26)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await deleteCommitment(commitment.id) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } else {
                Text("暂无")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Bond")
        } footer: {
            Text("当前关系状态。承诺可左滑删除；亲密度由反思服务渐进调整。")
        }
    }

    private func commitmentDateLabel(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = locale
        df.dateFormat = isEnglish ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return df.string(from: date)
    }

    /// "10 分钟后触发" / "已逾期 2 分钟（待下次心跳）" 等等
    private func commitmentDueLabel(dueAt: Date) -> String {
        let interval = dueAt.timeIntervalSince(Date())
        let absMin = Int(abs(interval) / 60)
        if interval <= 0 {
            return isEnglish ? "Due now" : "已到期（待心跳触发）"
        }
        if absMin < 1 {
            return isEnglish ? "Due soon" : "即将触发"
        }
        if absMin < 60 {
            return isEnglish ? "Due in \(absMin) min" : "\(absMin) 分钟后触发"
        }
        return isEnglish
            ? "Due in \(absMin / 60) hr \(absMin % 60) min"
            : "\(absMin / 60) 小时 \(absMin % 60) 分后触发"
    }

    // MARK: - Memory 加载 / 触发反思

    private func loadMemory() async {
        memorySnapshot = try? await appModel.storage.loadMemorySnapshot(
            personaID: snapshot.personaID
        )
        memoryLoaded = true
    }

    /// "立即触发反思"按钮：跑反思 → 重新加载 → UI 自动刷新
    private func runManualReflection() async {
        reflecting = true
        defer { reflecting = false }
        await appModel.triggerReflectionForCurrentPersona()
        await loadMemory()
    }

    // MARK: - 编辑 / 删除 handlers

    private func applyFactUpdate(_ updated: UserFact) async {
        guard var snap = memorySnapshot,
              let idx = snap.facts.firstIndex(where: { $0.id == updated.id }) else { return }
        snap.facts[idx] = updated
        snap.lastModified = Date()
        memorySnapshot = snap     // optimistic UI
        await appModel.saveMemorySnapshot(snap)
    }

    private func deleteFact(_ id: UUID) async {
        guard var snap = memorySnapshot else { return }
        snap.facts.removeAll { $0.id == id }
        snap.lastModified = Date()
        memorySnapshot = snap
        await appModel.saveMemorySnapshot(snap)
    }

    private func deleteEpisode(_ id: UUID) async {
        guard var snap = memorySnapshot else { return }
        snap.episodes.removeAll { $0.id == id }
        snap.lastModified = Date()
        memorySnapshot = snap
        await appModel.saveMemorySnapshot(snap)
    }

    private func deleteCommitment(_ id: UUID) async {
        guard var snap = memorySnapshot else { return }
        snap.bond.pendingCommitments.removeAll { $0.id == id }
        snap.bond.lastUpdated = Date()
        snap.lastModified = Date()
        memorySnapshot = snap
        await appModel.saveMemorySnapshot(snap)
    }

    // MARK: - 单条消息行

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleBadge(message.role))
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(roleColor(message.role))
                    .clipShape(Capsule())

                if let anim = message.animation {
                    Text("anim: \(anim)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(timeString(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func roleBadge(_ role: ChatMessage.Role) -> String {
        switch role {
        case .user:      return "USER"
        case .assistant: return "CHAR"
        }
    }

    private func roleColor(_ role: ChatMessage.Role) -> Color {
        switch role {
        case .user:      return .accentColor
        case .assistant: return .gray
        }
    }

    private func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = locale
        df.dateFormat = isEnglish ? "MMM d, HH:mm" : "MM-dd HH:mm"
        return df.string(from: date)
    }

    // MARK: - 派生

    private var personaName: String {
        CharacterPersona.load(named: snapshot.personaID)?.name ?? snapshot.personaID
    }

    private var isEnglish: Bool { locale.identifier.hasPrefix("en") }

    private var isCurrentPersona: Bool {
        appModel.currentPersona?.id == snapshot.personaID
    }

    private var deleteFooterText: String {
        if isEnglish {
            return isCurrentPersona
                ? "This is your current companion. Deleting its history will restart the chat."
                : "Other companions and the current chat are unaffected."
        }
        return isCurrentPersona
            ? "这是你当前正在聊的角色，删除后会自动重启对话（发新开场白）。"
            : "不影响其它角色，也不影响当前对话。"
    }
}
