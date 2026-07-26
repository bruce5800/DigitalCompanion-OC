//
//  AppModel.swift
//  DigitalCompanion
//
//  Created by 李卓伦 on 2026/3/28.
//
//  应用级状态 + 用户消息入口编排。
//  历史上这里什么都塞（走位、follow/自主循环、模型缓存……），
//  Phase 6 之后拆成三块：
//    - AppModel（本类）—— 全局状态 + processUserMessage + 角色切换 + 生命周期
//    - ModelCache —— USDZ LRU 缓存 + 动画挂载握手
//    - BehaviorOrchestrator —— performWalk / Sit / WalkToPoint + follow / 自主循环
//

import SwiftUI
import RealityKit
import RealityKitContent
import CompanionCore
import CompanionAvatar

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    /// 当前选中的动画 fileName（如 "furina_1站姿静止"）
    var selectedAnimation: String = ""

    // MARK: - 服务实例

    /// 对话服务（A0.2 起接入 CompanionStorage，每角色一份磁盘快照）
    let chatService: ChatService

    /// 持久化后端。TriggerService 通过它读写 memory 来扫描 commitments / 删除已触发的
    let storage: any CompanionStorage

    /// 当前使用的存储后端（iCloud / local）；仅用于日志 / 未来 UI 展示
    let storageBackend: StorageBackend

    /// 主动触发心跳（A4）。在 init 启动；fire 闭包里调 ChatService.fireProactiveMessage
    let triggerService = TriggerService()

    /// TTS 语音服务
    let ttsService = TTSService()

    /// ARKit 追踪服务（头部 + 手势）
    let trackingService = TrackingService()

    /// 语音识别服务（push-to-talk，握拳触发）
    let speechService = SpeechRecognitionService()

    /// 口型同步服务
    let lipSyncService = LipSyncService()

    /// 表情服务（主表情 + 眨眼 idle）
    let expressionService = ExpressionService()

    /// Performance（舞蹈 / 唱歌等长动作）编排
    let performanceService = PerformanceService()

    /// 角色走位编排（LLM walk_target 或手势触发）
    let movementService = MovementService()

    /// 场景理解（地板 / 座位 / 门窗）
    let sceneService = SceneUnderstandingService()

    /// USDZ 模型缓存 + 动画挂载握手
    let modelCache = ModelCache()

    /// 大动作编排：performWalk / performSit / follow / autonomous
    /// init 里构造（需要 self 引用，所以用隐式解包）
    @ObservationIgnored private(set) var behavior: BehaviorOrchestrator!

    // MARK: - 用户 / 角色状态

    /// 当前 LLM 服务商
    var selectedProvider: LLMProvider = .claude

    /// 当前角色人设
    var currentPersona: CharacterPersona?

    /// 用户侧 Persona（昵称 + 自我介绍），用于 Prompt 里的 {{user}} 宏
    var userPersona: UserPersona = UserPersonaStore.load()

    /// 内置角色 ID（OC 分叉：3 个原创角色）
    private static let builtinPersonaIDs = ["oc", "sg", "xo"]

    /// 全部可选角色 ID = 内置 + 用户自定义(捏人系统)。
    /// 计算属性:自定义角色在捏人间保存后,切换菜单下次打开即出现。
    var availablePersonaIDs: [String] {
        Self.builtinPersonaIDs + CustomPersonaStore.loadAll().map(\.id)
    }

    // MARK: - UI 状态

    /// 是否显示 API Key 设置
    var showAPIKeySetup = false

    /// 当前正在跑的 activate（恢复历史 / 发开场白）。快速切角色时取消上一个，
    /// 避免多个 activate 竞态导致念错角色的开场白。
    private var activationTask: Task<Void, Never>?

    /// 是否启用 TTS
    var isTTSEnabled = true

    /// 是否显示场景理解的调试可视化
    var isSceneVisualizationEnabled: Bool = false

    /// 上一次导航请求的结果（Phase 3 调试条）。nil = 没历史 / 走成了
    var lastNavigationNote: String?

    /// 角色当前行动模式。切换时委托 behavior 启/停 followTask / autonomousTask。
    var movementMode: MovementMode = .stationary {
        didSet {
            guard oldValue != movementMode else { return }
            behavior.handleMovementModeChange(from: oldValue, to: movementMode)
        }
    }

    /// 角色开场白。若切角色时 immersive space 尚未打开，暂存在这里，等打开后再播。
    @ObservationIgnored private var pendingGreeting: String?

    // MARK: - 初始化

    init() {
        // 选存储后端（iCloud 优先，不可用自动降级 local）
        let (storage, backend) = StorageFactory.makeDefault()
        self.storage = storage
        self.storageBackend = backend
        self.chatService = ChatService(storage: storage)

        self.behavior = BehaviorOrchestrator(appModel: self)
        switchCharacter(to: "oc")
        ttsService.lipSyncService = lipSyncService

        // 表演(唱歌):歌曲带 sidecar 口型曲线时,播放期间驱动嘴形
        performanceService.onPlaybackStarted = { [weak self] player, curve in
            guard let self, let curve else { return }
            self.lipSyncService.startCurve(curve, player: player)
        }
        performanceService.onPlaybackEnded = { [weak self] in
            self?.lipSyncService.stop()
        }

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

    /// 一条 commitment 到期被 TriggerService 召唤后执行：
    /// 1. guards：避免打断正在进行的对话 / 表演 / 走位
    /// 2. 调 ChatService.fireProactiveMessage 让 LLM 主动开口
    /// 3. 同 processUserMessage 那样处理 directives + TTS + 后续动作
    /// 4. 从 memory 移除该 commitment，避免下次心跳重复触发
    private func fireCommitment(_ commitment: PendingCommitment) async {
        guard let persona = currentPersona else { return }

        // Guards：跳过将留待下次心跳重试
        if chatService.isLoading { return }
        if performanceService.isPerforming { return }
        if movementService.isActive { return }

        // 构造 hint
        let userName = userPersona.name.isEmpty ? "旅行者" : userPersona.name
        let hint = "时机到了。你之前对 \(userName) 做过承诺：「\(commitment.description)」。现在用自然的方式主动开口提及。"

        let context = ContextSnapshot(
            now: Date(),
            activity: currentActivityDescription,
            scene: sceneService.summarize()
        )

        var pendingPerformance: CharacterPersona.AnimationMapping?
        var pendingWalk: WalkTarget?

        let success = await chatService.fireProactiveMessage(
            promptHint: hint,
            persona: persona,
            userPersona: userPersona,
            provider: selectedProvider,
            mode: .spatial,
            context: context
        ) { [weak self] animID, expressionID, walkTargetRaw in
            guard let self else { return }
            if let raw = expressionID, let expr = FacialExpression(rawValue: raw) {
                self.expressionService.setExpression(expr)
            }
            if let raw = walkTargetRaw {
                if let target = WalkTarget(rawValue: raw) {
                    pendingWalk = target
                }
            }
            guard let mapping = persona.animation(forAPIName: animID) else { return }
            if mapping.isPerformance {
                pendingPerformance = mapping
            } else if !mapping.isWalk {
                self.selectedAnimation = mapping.fileName
            }
        }

        guard success else { return }

        // TTS（与 processUserMessage 一致）
        if isTTSEnabled,
           let last = chatService.messages.last,
           last.role == .assistant {
            ttsService.speak(last.text)
            await ttsService.waitForCompletion()
        }
        if let perf = pendingPerformance {
            await runPerformance(perf)
        }
        if let walk = pendingWalk {
            await performWalk(walk)
        }

        // 触发成功 → 从 memory 移除该 commitment
        if var memory = try? await storage.loadMemorySnapshot(personaID: persona.id) {
            memory.bond.pendingCommitments.removeAll { $0.id == commitment.id }
            memory.bond.lastUpdated = Date()
            memory.lastModified = Date()
            try? await storage.saveMemorySnapshot(memory)
            print("✨ Commitment 触发并移除：\(commitment.description)")
        }
    }

    // MARK: - 生命周期

    /// ImmersiveSpace 打开后由 App 调用：播挂起的开场白 + 启动场景扫描
    func onImmersiveSpaceOpened() {
        Task { await sceneService.start() }

        guard let greeting = pendingGreeting, isTTSEnabled else {
            pendingGreeting = nil
            return
        }
        pendingGreeting = nil
        ttsService.speak(greeting)
    }

    /// ImmersiveSpace 关闭时停掉场景扫描 + 把行动模式收回静态
    /// —— follow / autonomous 依赖头部追踪 / 场景数据，关了都没了
    func onImmersiveSpaceClosed() {
        sceneService.stop()
        // 握拳录音时若关闭沉浸空间，onChange 不一定能触发 stopListening → 麦克风会一直开着。
        // 在这里兜底停掉，避免关空间后还在偷偷录音（隐私）。
        speechService.stopListening()
        if movementMode != .stationary {
            movementMode = .stationary
        }
    }

    // MARK: - 用户消息处理（主入口）

    /// 用户消息进入系统的唯一入口。
    /// 负责编排：表演排队 / LLM 调用 / TTS / performance 动作触发 / queue flush
    func processUserMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 表演期间 → 消息入队，表演结束后统一 flush 发送
        if performanceService.isPerforming {
            performanceService.queueMessage(trimmed)
            return
        }

        guard let persona = currentPersona else {
            chatService.errorMessage = "未加载角色配置"
            return
        }

        // LLM 若选中 performance 动画，先不切——等 TTS 说完再触发
        var pendingPerformance: CharacterPersona.AnimationMapping?
        var pendingWalk: WalkTarget?

        // A2：构造 visionOS 端的 context（活动 + 场景），ChatService 会自动补 previousInteractionTime
        let context = ContextSnapshot(
            now: Date(),
            activity: currentActivityDescription,
            scene: sceneService.summarize()
        )

        await chatService.send(
            userMessage: trimmed,
            persona: persona,
            userPersona: userPersona,
            provider: selectedProvider,
            mode: .spatial,
            context: context
        ) { [weak self] animID, expressionID, walkTargetRaw in
            guard let self else { return }
            // 期间用户切了角色 → 这条回复的动作/表情不该落到新角色身上
            guard self.currentPersona?.id == persona.id else { return }

            // 表情（可选）：立即生效，不受 TTS / performance 时序影响
            if let raw = expressionID, let expr = FacialExpression(rawValue: raw) {
                self.expressionService.setExpression(expr)
            }

            // 走位（可选）：延迟到 TTS 说完再执行
            if let raw = walkTargetRaw {
                if let target = WalkTarget(rawValue: raw) {
                    pendingWalk = target
                } else {
                    print("⚠️ LLM 返回了未知的 walk_target: \(raw)")
                }
            }

            // 动画：performance 类动画延迟到 TTS 之后再切；walk 类由 performWalk 统一管
            guard let mapping = persona.animation(forAPIName: animID) else { return }
            if mapping.isPerformance {
                pendingPerformance = mapping
            } else if !mapping.isWalk {
                // walk 不应该被 LLM 直接选；如果真被选了也忽略，改走 walk_target 路径
                self.selectedAnimation = mapping.fileName
            }
        }

        // 期间用户若切了角色 → 这次回复的 TTS / 动作 / 走位都不该落到新角色身上
        guard currentPersona?.id == persona.id else { return }

        // TTS 朗读最新的助手回复，等它说完
        if isTTSEnabled,
           let last = chatService.messages.last,
           last.role == .assistant {
            ttsService.speak(last.text)
            await ttsService.waitForCompletion()
        }

        // 触发 performance（如果 LLM 选了）
        if let perf = pendingPerformance {
            await runPerformance(perf)
        }

        // 触发走位（如果 LLM 选了）
        if let walk = pendingWalk {
            await performWalk(walk)
        }
    }

    /// 触发一次 performance：切动画 → 播音频（阻塞）→ 切回 → flush 队列。
    /// internal（非 private）：BehaviorOrchestrator 自主模式 initiate_talk 后也要复用。
    func runPerformance(_ mapping: CharacterPersona.AnimationMapping) async {
        guard let audioName = mapping.audioFile else {
            print("⚠️ performance 动画 \(mapping.id) 未配置 audioFile，跳过")
            return
        }

        let previousAnimation = selectedAnimation
        selectedAnimation = mapping.fileName

        await performanceService.play(audioFileBaseName: audioName)

        selectedAnimation = previousAnimation

        // flush 队列：期间排队的消息合并为一条用户消息递归处理
        if let combined = performanceService.flushQueue() {
            await processUserMessage(combined)
        }
    }

    // MARK: - 行为编排转发
    //
    // AppModel 的公开 API 保持不变；底层实现已迁到 BehaviorOrchestrator。
    // ImmersiveView / ContentView 原来的 appModel.performWalk(...) 等调用点无需修改。

    /// 相对用户的走位（towardUser / backward / closer / farther）
    func performWalk(_ target: WalkTarget) async {
        await behavior.performWalk(target)
    }

    /// 走到场景中某个绝对世界位置
    func performWalkToPoint(
        target: SIMD3<Float>,
        faceYaw: Float? = nil,
        validate: Bool = true
    ) async {
        await behavior.performWalkToPoint(target: target, faceYaw: faceYaw, validate: validate)
    }

    /// 走到座位并坐下
    func performSit(at seat: Seat) async {
        await behavior.performSit(at: seat)
    }

    // MARK: - 模型加载转发
    //
    // 保留 API：ImmersiveView.loadAndAttach 调 appModel.loadModel(...)，
    // ContentView 读 appModel.isLoadingModel，DigitalCompanionApp 切角色时 clearModelCache()。

    func loadModel(fileName: String) async -> Entity? {
        guard let entity = await modelCache.loadModel(fileName: fileName) else { return nil }
        await applyAvatarRecipeIfCustom(to: entity)
        return entity
    }

    /// 当前角色是自定义角色时,把保存的外观配方(部件/捏脸/发色)应用到
    /// 刚加载的实体上。发生在 ImmersiveView attach + setupLipSync **之前**,
    /// 所以口型订阅拿到的是重建后的 mesh,索引不会作废。
    /// 注意:作用于 clone(不动缓存模板);捏人间改完配方保存时会 clearModelCache,
    /// 但即便不清,这里每次 attach 都重新读配方,结果也是新的。
    private func applyAvatarRecipeIfCustom(to entity: Entity) async {
        guard let persona = currentPersona,
              CustomPersonaStore.persona(id: persona.id) != nil else { return }
        do {
            guard let recipe = try await storage.loadAvatarRecipe(personaID: persona.id) else { return }
            let composer = try AvatarComposer(character: entity)
            try composer.apply(recipe)
        } catch {
            print("⚠️ 自定义外观应用失败(用素体继续): \(error)")
        }
    }

    var isLoadingModel: Bool {
        modelCache.isLoadingModel
    }

    func notifyAnimationAttached(_ fileName: String) {
        modelCache.notifyAnimationAttached(fileName)
    }

    func awaitAnimationAttached(_ fileName: String) async {
        await modelCache.awaitAnimationAttached(fileName)
    }

    func clearModelCache() {
        modelCache.clear()
    }

    // MARK: - 角色切换

    /// 切换到指定角色。
    /// A0.2 起每个角色独立保留对话历史：切回旧角色会恢复记录，不会丢。
    /// 第一次遇到的角色或磁盘无历史时，自动发开场白。
    func switchCharacter(to personaID: String) {
        guard let persona = CharacterPersona.load(named: personaID) else {
            print("❌ 无法加载角色: \(personaID)")
            return
        }
        currentPersona = persona
        performanceService.stop()
        expressionService.stop()
        movementService.cancel()
        // 应用角色级 blink 开关（常态闭眼的角色如哥伦比娅需要禁用）
        expressionService.isBlinkEnabled = persona.blinkEnabled ?? true
        clearModelCache()
        ttsService.stop()

        // 切换 TTS 音色（云端 Fish Audio + Apple 兜底的角色化音色）
        ttsService.fishAudioReferenceID = persona.voiceId ?? ""
        // 自定义角色带声线预设 → 用它;否则按 personaID 走内置预设(oc/sg/xo)
        ttsService.appleVoiceProfile = persona.appleVoicePreset.flatMap { .preset(named: $0) }
            ?? .preset(forPersonaID: personaID)

        // 设为第一个动画
        if let first = persona.animations.first {
            selectedAnimation = first.fileName
        }

        // activate 负责：从磁盘恢复历史 / 没历史时发开场白
        activationTask?.cancel()
        activationTask = Task { @MainActor in
            let greeting = await chatService.activate(
                persona: persona,
                userPersona: userPersona,
                freshStart: false
            )
            if Task.isCancelled { return }   // 期间又切了角色 → 别念这个开场白
            if let greeting, isTTSEnabled {
                speakOrDefer(greeting)
            }
            // A4：切角色后立刻扫一次 commitments，避免错过已过期的
            await triggerService.checkNow()
        }
    }

    /// 更新用户 Persona：持久化 + 强制重启当前角色对话（换名字后角色该重新"认识"你）
    func updateUserPersona(_ newValue: UserPersona) {
        guard newValue != userPersona else { return }
        userPersona = newValue
        UserPersonaStore.save(newValue)
        if let persona = currentPersona {
            performanceService.stop()
            expressionService.stop()
            movementService.cancel()
            ttsService.stop()
            activationTask?.cancel()
            activationTask = Task { @MainActor in
                let greeting = await chatService.activate(
                    persona: persona,
                    userPersona: newValue,
                    freshStart: true
                )
                if Task.isCancelled { return }
                if let greeting, isTTSEnabled {
                    speakOrDefer(greeting)
                }
            }
        }
    }

    /// "清空对话"按钮用：强制 freshStart 当前角色（清磁盘记录 + 重新发开场白）
    func resetCurrentChat() {
        guard let persona = currentPersona else { return }
        performanceService.stop()
        expressionService.stop()   // 与 switchCharacter 一致：清空对话也要把表情恢复中性
        movementService.cancel()
        ttsService.stop()
        activationTask?.cancel()
        activationTask = Task { @MainActor in
            let greeting = await chatService.activate(
                persona: persona,
                userPersona: userPersona,
                freshStart: true
            )
            if Task.isCancelled { return }
            if let greeting, isTTSEnabled {
                speakOrDefer(greeting)
            }
        }
    }

    /// immersive space 开着就直接播；没开就挂起，等 onImmersiveSpaceOpened 再播
    private func speakOrDefer(_ greeting: String) {
        if immersiveSpaceState == .open {
            ttsService.speak(greeting)
            pendingGreeting = nil
        } else {
            pendingGreeting = greeting
        }
    }

    // MARK: - 派生状态（给 UI / ImmersiveView 读）

    /// 从 persona 中反查当前动画的显示名
    var selectedAnimationDisplayName: String {
        currentPersona?.animations.first(where: { $0.fileName == selectedAnimation })?.displayName ?? ""
    }

    /// 当前是否处于坐姿状态（selectedAnimation 是 kind:"sit" 的动画）
    /// —— 坐姿期间应禁用目光跟随（角色在椅子上旋转很别扭）
    var isSitting: Bool {
        guard let mapping = currentPersona?.animations.first(where: { $0.fileName == selectedAnimation }) else {
            return false
        }
        return mapping.isSit
    }

    /// 检查当前服务商是否已配置 API Key
    var isAPIKeyConfigured: Bool {
        KeychainService.load(forAccount: selectedProvider.keychainAccount) != nil
    }

    // MARK: - A2 情境感知

    /// "你正在做什么"的一句话总结。优先级从高到低：
    /// 表演中 > 走位中 > 坐着 > follow > autonomous > 静态站立。
    /// 给 LLM 用，方便它"知道自己的身体状态"。
    var currentActivityDescription: String {
        if performanceService.isPerforming {
            return "正在表演中（跳舞 / 唱歌）"
        }
        if movementService.isActive {
            return "正在走过去"
        }
        if isSitting {
            return "正坐着"
        }
        if immersiveSpaceState != .open {
            return "尚未出现在 \(userPersona.name) 身边（沉浸空间未打开）"
        }
        switch movementMode {
        case .follow:     return "在 \(userPersona.name) 身边跟着走"
        case .autonomous: return "在房间里自己活动"
        case .stationary: return "站着等 \(userPersona.name) 说话"
        }
    }
}
