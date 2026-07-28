//
//  PhoneAppModel.swift
//  DigitalCompanionPhone
//
//  iPhone 端的全局状态 —— 是 visionOS AppModel 的 chat-only 子集。
//
//  **有意不与 visionOS AppModel 共享代码**，原因：
//    - visionOS AppModel 深度绑定 RealityKit / ARKit / scene 服务
//    - iPhone 只需要对话 + 持久化，抽共用基类反而带来不必要的条件编译
//    - 等 Phase A1 引入 MemoryService 时，再看是否值得抽 ChatCoordinator
//
//  与 visionOS AppModel 的关键差异：
//    - 没有 TTS / LipSync / Expression / Scene / Movement 服务
//    - processUserMessage 的 onDirectives 回调里**丢弃** animation / expression / walk
//      （iPhone 没有身体可以动，只关心文字）
//    - 开场白不播 TTS，只作为第一条 assistant 消息出现在列表里
//

import SwiftUI
import CompanionCore

@MainActor
@Observable
final class PhoneAppModel {

    // MARK: - 核心服务

    let chatService: ChatService
    /// 持久化后端。Memory Inspector 会直接用它查/删其它角色的快照
    /// （ChatService 只管当前角色的内存状态，不提供跨角色查询）
    let storage: any CompanionStorage
    let storageBackend: StorageBackend

    /// 主动触发心跳（A4）。在 init 启动，扫到期 commitments
    let triggerService = TriggerService()

    // MARK: - 角色 / 用户

    var currentPersona: CharacterPersona?
    var userPersona: UserPersona = UserPersonaStore.load()
    let availablePersonaIDs = ["oc", "sg", "xo"]  // OC 分叉 (3 个原创角色)

    // MARK: - LLM 配置

    var selectedProvider: LLMProvider = .claude

    // MARK: - UI 状态

    var showAPIKeySetup = false
    var showSettings = false

    // MARK: - 初始化

    init() {
        let (storage, backend) = StorageFactory.makeDefault()
        self.storage = storage
        self.storageBackend = backend
        self.chatService = ChatService(storage: storage)
        switchCharacter(to: "oc")

        // A4：启动主动触发心跳
        startTriggerLoop()
    }

    // MARK: - A4 主动触发

    private func startTriggerLoop() {
        triggerService.start(
            fetchMemory: { [weak self] in
                guard let self, let persona = self.currentPersona else { return nil }
                return try? await self.storage.loadMemorySnapshot(personaID: persona.id)
            },
            fire: { [weak self] commitment in
                await self?.fireCommitment(commitment)
            }
        )
    }

    /// 触发器召唤：iPhone 端简化版（无 TTS / 表演 / 走位）
    private func fireCommitment(_ commitment: PendingCommitment) async {
        guard let persona = currentPersona else { return }
        if chatService.isLoading { return }

        let userName = userPersona.name.isEmpty ? "旅行者" : userPersona.name
        let hint = "时机到了。你之前对 \(userName) 做过承诺：「\(commitment.description)」。现在用自然的方式主动开口提及。"

        let success = await chatService.fireProactiveMessage(
            promptHint: hint,
            persona: persona,
            userPersona: userPersona,
            provider: selectedProvider,
            mode: .text,
            context: ContextSnapshot(now: Date())
        )

        guard success else { return }

        // 从 memory 移除已触发的 commitment
        if var memory = try? await storage.loadMemorySnapshot(personaID: persona.id) {
            memory.bond.pendingCommitments.removeAll { $0.id == commitment.id }
            memory.bond.lastUpdated = Date()
            memory.lastModified = Date()
            try? await storage.saveMemorySnapshot(memory)
            print("✨ Commitment 触发并移除：\(commitment.description)")
        }
    }

    // MARK: - Memory Inspector 支持

    /// 删除某个角色的磁盘记录（chat + memory 一起删）
    /// 如果删的是当前角色，顺便把内存也刷掉
    func deletePersonaHistory(_ personaID: String) async {
        try? await storage.deleteChatSnapshot(personaID: personaID)
        try? await storage.deleteMemorySnapshot(personaID: personaID)
        // 删的是当前在聊的角色 → 重新 activate（会发新开场白）
        if let current = currentPersona, current.id == personaID {
            let greeting = await chatService.activate(
                persona: current,
                userPersona: userPersona,
                freshStart: true
            )
            _ = greeting  // 手机端没 TTS，不播
        }
    }

    /// Inspector 编辑/删除 fact / episode / commitment 时，更新后调用本方法持久化
    func saveMemorySnapshot(_ snapshot: MemorySnapshot) async {
        do {
            try await storage.saveMemorySnapshot(snapshot)
        } catch {
            print("⚠️ 保存 memory snapshot 失败：\(error)")
        }
    }

    /// 立即触发当前角色的记忆反思（手动触发，不等阈值）。
    /// 反思会异步落盘到 memory_{id}.json；调用方一般在反思后重新加载 MemorySnapshot 看效果。
    func triggerReflectionForCurrentPersona() async {
        guard let persona = currentPersona else { return }
        await chatService.triggerReflectionNow(
            persona: persona,
            userPersona: userPersona,
            provider: selectedProvider
        )
    }

    /// 清空所有角色的磁盘记录（chat + memory）+ 重置当前角色
    func wipeAllHistory() async {
        let ids = (try? await storage.listStoredPersonaIDs()) ?? []
        for id in ids {
            try? await storage.deleteChatSnapshot(personaID: id)
            try? await storage.deleteMemorySnapshot(personaID: id)
        }
        if let current = currentPersona {
            _ = await chatService.activate(
                persona: current,
                userPersona: userPersona,
                freshStart: true
            )
        }
    }

    // MARK: - 角色切换

    /// 切角色：有磁盘历史就恢复，没有就发开场白
    func switchCharacter(to personaID: String) {
        guard let persona = CharacterPersona.load(named: personaID) else {
            print("❌ 无法加载角色: \(personaID)")
            return
        }
        currentPersona = persona
        Task { @MainActor in
            await chatService.activate(
                persona: persona,
                userPersona: userPersona,
                freshStart: false
            )
            // A4：切角色后立刻扫一次 commitments，避免错过已过期的
            await triggerService.checkNow()
        }
    }

    // MARK: - 用户消息

    /// 发送用户消息
    /// iPhone 端忽略 animation / expression / walk_target —— 这些是给虚拟角色"身体"的指令，
    /// 手机没有身体，只留对话文本
    func processUserMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let persona = currentPersona else {
            chatService.errorMessage = "未加载角色配置"
            return
        }
        await chatService.send(
            userMessage: trimmed,
            persona: persona,
            userPersona: userPersona,
            provider: selectedProvider,
            mode: .text,
            // A2：iPhone 没有身体也没有房间，只能提供时间维度的 context；
            // ChatService 内部会自动补上 previousInteractionTime
            context: ContextSnapshot(now: Date()),
            onDirectives: { _, _, _ in
                // iPhone 永远 text 模式，response 里 animation/expression/walk 全 nil；
                // 这个闭包不会被有效调用，留空保留接口形态
            }
        )
    }

    // MARK: - 设置更新

    /// 用户 Persona 变更 → 持久化；昵称/描述变化才重启对话，单独换头像不打断聊天。
    func updateUserPersona(_ newValue: UserPersona) {
        guard newValue != userPersona else { return }
        let shouldRestartConversation =
            newValue.name != userPersona.name
            || newValue.description != userPersona.description
        userPersona = newValue
        UserPersonaStore.save(newValue)
        guard shouldRestartConversation else { return }
        guard let persona = currentPersona else { return }
        Task { @MainActor in
            await chatService.activate(
                persona: persona,
                userPersona: newValue,
                freshStart: true
            )
        }
    }

    /// 清空当前角色的磁盘记录 + 重新发开场白
    func resetCurrentChat() {
        guard let persona = currentPersona else { return }
        Task { @MainActor in
            await chatService.activate(
                persona: persona,
                userPersona: userPersona,
                freshStart: true
            )
        }
    }

    // MARK: - 派生状态

    var isAPIKeyConfigured: Bool {
        KeychainService.load(forAccount: selectedProvider.keychainAccount) != nil
    }

    /// 当前角色显示名
    var currentPersonaName: String {
        currentPersona?.name ?? "选择角色"
    }
}
