//
//  BehaviorOrchestrator.swift
//  DigitalCompanion
//
//  角色的"大动作"编排层：
//  - performWalk         —— 相对用户的走位（towardUser / backward / closer / farther）
//  - performWalkToPoint  —— 走到场景中任意世界坐标
//  - performSit          —— 走到座位并坐下（复用 performWalkToPoint）
//  - Follow 循环         —— 跟随用户（侧后方 45° @ 1m）
//  - Autonomous 循环     —— 自主 FSM（wander / observePOI / sit / idle）
//
//  从 AppModel 拆出来，AppModel 只保留状态 + processUserMessage 入口。
//  所有方法通过 `appModel` 访问 service 实例和共享状态（selectedAnimation /
//  lastNavigationNote / currentPersona），保持 API 不变。
//

import Foundation
import simd
import CompanionCore

@MainActor
final class BehaviorOrchestrator {

    /// 宿主 AppModel —— 走位需要读/写它的 selectedAnimation / lastNavigationNote，
    /// 以及调用 services（movement / tracking / scene / performance / chat / tts）。
    /// unowned 因为 AppModel 的生命周期必然 ≥ Orchestrator 的（是其属性）。
    unowned let appModel: AppModel

    // MARK: - 后台循环任务

    private var followTask: Task<Void, Never>?
    private var autonomousTask: Task<Void, Never>?

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    // MARK: - 模式切换入口（AppModel.movementMode.didSet 调用）

    /// 启/停 follow / autonomous task，取消在途 walk。
    func handleMovementModeChange(from old: MovementMode, to new: MovementMode) {
        print("🎯 行动模式：\(old.rawValue) → \(new.rawValue)")
        switch new {
        case .stationary:
            stopFollowTask()
            stopAutonomousTask()
            // 切出非静态模式时，cancel 正在走的 walk，让角色原地停下
            if old != .stationary { appModel.movementService.cancel() }
        case .follow:
            stopFollowTask()
            stopAutonomousTask()
            startFollowTask()
        case .autonomous:
            stopFollowTask()
            stopAutonomousTask()
            startAutonomousTask()
        }
    }

    // MARK: - Phase 2/3：走位

    /// 执行一次走位：转身 → 切 walk 动画 → 移动 → 切回 idle → 转回
    func performWalk(_ target: WalkTarget) async {
        guard let persona = appModel.currentPersona,
              let walkMap = persona.animation(forAPIName: "walk") else {
            print("⚠️ 当前角色未注册 walk 动画，跳过走位")
            return
        }

        let movement = appModel.movementService
        let previousAnimation = appModel.selectedAnimation
        let startPos = movement.currentAnchorPosition
        let startYaw = movement.currentAnchorYaw

        // 用户头部的 XZ 平面投影；y 保持 anchor 当前值
        let headPos = appModel.trackingService.headPosition
        let userGroundPos = SIMD3<Float>(headPos.x, startPos.y, headPos.z)

        // dir 指向用户；若用户正好贴在角色上，退化为 +Z 轴避免除零
        let diff = userGroundPos - startPos
        let flatDist = simd_length(SIMD2<Float>(diff.x, diff.z))
        let towardUserYaw: Float = flatDist > 0.01 ? atan2(diff.x, diff.z) : startYaw
        let unitTowardUser: SIMD3<Float>
        if flatDist > 0.01 {
            unitTowardUser = SIMD3<Float>(diff.x / flatDist, 0, diff.z / flatDist)
        } else {
            unitTowardUser = SIMD3<Float>(0, 0, 1)
        }

        // 计算目标位置 & 是否需要"转身走再转回"
        let stopDistanceFromUser: Float = 1.2
        let targetPos: SIMD3<Float>
        let needTurnAround: Bool

        switch target {
        case .towardUser:
            if flatDist > stopDistanceFromUser + 0.1 {
                targetPos = userGroundPos - unitTowardUser * stopDistanceFromUser
            } else {
                targetPos = startPos
            }
            needTurnAround = false
        case .closer:
            targetPos = startPos + unitTowardUser * min(0.5, max(0, flatDist - stopDistanceFromUser))
            needTurnAround = false
        case .backward:
            targetPos = startPos - unitTowardUser * 0.8
            needTurnAround = true
        case .farther:
            targetPos = startPos - unitTowardUser * 0.5
            needTurnAround = true
        }

        // 几乎不动（< 5cm）就跳过整个流程
        let moveDist = simd_distance(targetPos, startPos)
        if moveDist < 0.05 { return }

        movement.begin()

        let walkYaw: Float = needTurnAround
            ? normalizeYaw(towardUserYaw + .pi)
            : towardUserYaw
        if abs(normalizeYaw(walkYaw - startYaw)) > 0.05 {
            movement.requestYaw(walkYaw)
            await movement.waitYawArrival()
        }

        // 切到 walk 动画，等挂载完成再开始平移
        appModel.selectedAnimation = walkMap.fileName
        await appModel.modelCache.awaitAnimationAttached(walkMap.fileName)

        movement.requestPosition(targetPos)
        await movement.waitPositionArrival()

        // 切回之前的动画
        appModel.selectedAnimation = previousAnimation

        // 背对走完要把朝向转回用户
        if needTurnAround {
            movement.requestYaw(towardUserYaw)
            await movement.waitYawArrival()
        }

        movement.end()
    }

    /// 走到场景中某个绝对世界位置（不是相对用户）。
    /// - target: 目标 XZ；Y 会被强制覆盖为 anchor 的当前 Y
    /// - faceYaw: 到达后朝向（弧度，绕 Y）；nil 表示保留运动方向
    /// - validate: 是否先做 NavigationService 可达性检查
    func performWalkToPoint(
        target: SIMD3<Float>,
        faceYaw: Float? = nil,
        validate: Bool = true
    ) async {
        guard let persona = appModel.currentPersona,
              let walkMap = persona.animation(forAPIName: "walk") else {
            appModel.lastNavigationNote = "当前角色未配置 walk 动画"
            print("⚠️ \(appModel.lastNavigationNote ?? "")")
            return
        }

        let movement = appModel.movementService
        let startPos = movement.currentAnchorPosition
        let targetPos = SIMD3<Float>(target.x, startPos.y, target.z)

        let moveDist = simd_distance(targetPos, startPos)
        if moveDist < 0.05 {
            appModel.lastNavigationNote = "已经在目标附近"
            return
        }

        // 可达性检查
        if validate {
            let r = NavigationService.checkReachability(
                from: startPos, to: targetPos, scene: appModel.sceneService
            )
            switch r {
            case .ok:
                break
            case .targetOffFloor:
                appModel.lastNavigationNote = "目标不在 floor 内"
                print("🚧 导航失败：目标不在 floor 多边形内（可能要补扫或换座位）")
                return
            case .blocked(let kind):
                appModel.lastNavigationNote = "路径被 \(kind) 挡住"
                print("🚧 导航失败：直线被障碍（\(kind)）挡住；暂不绕行")
                return
            }
        }

        let startYaw = movement.currentAnchorYaw
        let previousAnimation = appModel.selectedAnimation

        let diff = targetPos - startPos
        let moveYaw = atan2(diff.x, diff.z)

        movement.begin()

        if abs(normalizeYaw(moveYaw - startYaw)) > 0.05 {
            movement.requestYaw(moveYaw)
            await movement.waitYawArrival()
        }

        appModel.selectedAnimation = walkMap.fileName
        await appModel.modelCache.awaitAnimationAttached(walkMap.fileName)

        movement.requestPosition(targetPos)
        await movement.waitPositionArrival()

        appModel.selectedAnimation = previousAnimation

        // 到位后的最终朝向
        if let face = faceYaw, abs(normalizeYaw(face - moveYaw)) > 0.05 {
            movement.requestYaw(face)
            await movement.waitYawArrival()
        }

        movement.end()
        appModel.lastNavigationNote = nil
    }

    // MARK: - Phase 5：坐下编排

    /// 走到座位并坐下。若未能真正到达（被阻挡）就保持站姿，不强切 sitIdle。
    func performSit(at seat: Seat) async {
        guard let persona = appModel.currentPersona else { return }
        let sitMap = persona.animations.first(where: { $0.isSit })

        let beforePos = appModel.movementService.currentAnchorPosition
        await performWalkToPoint(target: seat.center, faceYaw: seat.yaw)

        let afterPos = appModel.movementService.currentAnchorPosition
        let arrived = simd_distance(
            SIMD2<Float>(afterPos.x, afterPos.z),
            SIMD2<Float>(seat.center.x, seat.center.z)
        ) < 0.3
        let alreadyThere = simd_distance(
            SIMD2<Float>(beforePos.x, beforePos.z),
            SIMD2<Float>(seat.center.x, seat.center.z)
        ) < 0.3

        guard arrived || alreadyThere else {
            print("⚠️ 未能走到座位，保持站姿")
            return
        }

        guard let sit = sitMap else {
            print("⚠️ 当前角色未配置 sitIdle 动画，跳过坐姿切换")
            return
        }
        appModel.selectedAnimation = sit.fileName
    }

    // MARK: - Phase 4：Follow 模式

    private enum FollowConfig {
        static let distance: Float = 1.0
        static let offsetYaw: Float = 3 * .pi / 4          // 侧后方 45°
        static let triggerDistance: Float = 0.6
        static let tickInterval: UInt64 = 500_000_000      // 0.5 s
    }

    private func startFollowTask() {
        followTask = Task { [weak self] in
            await self?.followLoop()
        }
    }

    private func stopFollowTask() {
        followTask?.cancel()
        followTask = nil
    }

    private func followLoop() async {
        while !Task.isCancelled {
            if appModel.immersiveSpaceState == .open && appModel.sceneService.isReady {
                await followStep()
            }
            try? await Task.sleep(nanoseconds: FollowConfig.tickInterval)
        }
    }

    private func followStep() async {
        let userPos = appModel.trackingService.headPosition
        let userYaw = appModel.trackingService.headYaw
        let anchorPos = appModel.movementService.currentAnchorPosition

        let totalYaw = normalizeYaw(userYaw + FollowConfig.offsetYaw)
        let idealXZ = SIMD2<Float>(
            userPos.x + sin(totalYaw) * FollowConfig.distance,
            userPos.z + cos(totalYaw) * FollowConfig.distance
        )
        let ideal = SIMD3<Float>(idealXZ.x, anchorPos.y, idealXZ.y)

        let gap = simd_length(SIMD2<Float>(ideal.x - anchorPos.x, ideal.z - anchorPos.z))
        guard gap > FollowConfig.triggerDistance else { return }

        let reach = NavigationService.checkReachability(
            from: anchorPos, to: ideal, scene: appModel.sceneService
        )
        guard case .ok = reach else { return }

        let faceYaw = atan2(userPos.x - ideal.x, userPos.z - ideal.z)
        await performWalkToPoint(target: ideal, faceYaw: faceYaw, validate: false)
    }

    // MARK: - Phase 6：Autonomous FSM
    //
    // 动作集合：wander / observePOI / sit / standAndWander / idle
    // 避让：LLM / TTS / performance 忙时跳过本 tick，不抢话。

    private enum AutonomousConfig {
        /// 最近 30s 内有消息 → 算"活跃对话期"，决策更勤
        static let activeWindowSec: TimeInterval = 30
        /// 活跃期 tick 间隔（10-20s 随机抖动，避免拍点感）
        static let activeTickMinSec: UInt64 = 10_000_000_000
        static let activeTickMaxSec: UInt64 = 20_000_000_000
        /// 空闲期 tick 间隔（60-90s，节流 API 成本）
        static let idleTickMinSec: UInt64 = 60_000_000_000
        static let idleTickMaxSec: UInt64 = 90_000_000_000

        static let minWanderDistance: Float = 0.6
        static let poiStandOffDistance: Float = 1.0
        static let maxSampleAttempts: Int = 10

        /// 记忆里保留多少条最近 actions 给下一次决策看
        static let recentActionsCapacity: Int = 5
    }

    /// 自主动作的"富"枚举 —— 执行器需要原始 Seat / POI / topic
    private enum AutonomousAction {
        case wander
        case observe(PointOfInterest)
        case sit(Seat)
        case idle
        case initiateTalk(topicHint: String)
    }

    /// 给 LLM 看的"最近做过什么"。只存简短描述。
    private struct RecentActionRecord {
        let at: Date
        let summary: String
    }
    private var recentActions: [RecentActionRecord] = []

    private func startAutonomousTask() {
        recentActions.removeAll()  // 每次启动从新会话开始
        autonomousTask = Task { [weak self] in
            await self?.autonomousLoop()
        }
    }

    private func stopAutonomousTask() {
        autonomousTask?.cancel()
        autonomousTask = nil
    }

    private func autonomousLoop() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 起步缓冲
        while !Task.isCancelled {
            if appModel.immersiveSpaceState == .open && appModel.sceneService.isReady {
                await autonomousStep()
            }
            let interval = nextTickInterval()
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    /// 自适应 tick：最近有对话用短间隔，没对话用长间隔（省 API 成本）
    private func nextTickInterval() -> UInt64 {
        let lastTime = appModel.chatService.messages.last?.timestamp
        let recent = lastTime.map { Date().timeIntervalSince($0) < AutonomousConfig.activeWindowSec } ?? false
        if recent {
            return UInt64.random(in: AutonomousConfig.activeTickMinSec...AutonomousConfig.activeTickMaxSec)
        } else {
            return UInt64.random(in: AutonomousConfig.idleTickMinSec...AutonomousConfig.idleTickMaxSec)
        }
    }

    /// 一次决策周期：guards → LLM 决策 → 执行
    private func autonomousStep() async {
        // 不打断进行中的事情
        if appModel.chatService.isLoading
            || appModel.performanceService.isPerforming
            || appModel.ttsService.isSpeaking {
            return
        }
        if appModel.movementService.isActive { return }

        // 调 LLM 决策
        guard let decision = await decideViaLLM() else { return }

        // 把 LLM 决策翻译成 rich AutonomousAction
        let action = resolveAction(from: decision)

        // 记入 ring buffer，给下一次决策看
        record(action: action)

        // 调试日志：LLM 的"理由"
        let reasonText = decision.reason ?? "（无理由）"
        print("🤖 自主决策：\(decision.action.rawValue)\(decision.targetID.map { " → \($0)" } ?? "") | \(reasonText)")

        // 执行
        await execute(action)
    }

    /// 调 LLM 拿决策；任何失败都返回 nil 让本次 tick 跳过
    private func decideViaLLM() async -> AutonomousDecision? {
        guard let persona = appModel.currentPersona else { return nil }

        let llm: any LLMService
        do {
            llm = try makeLLMService()
        } catch {
            print("⚠️ 自主决策跳过：\(error)")
            return nil
        }

        // 加载记忆（供 LLM 看亲密度等）
        let memory = try? await appModel.storage.loadMemorySnapshot(personaID: persona.id)

        // 构造可选目标列表
        let observeTargets: [AutonomousTargetOption] = appModel.sceneService.pointsOfInterest.map {
            AutonomousTargetOption(
                id: $0.id.uuidString,
                label: $0.kind == .window ? "window" : "door"
            )
        }
        let seatTargets: [AutonomousTargetOption] = appModel.sceneService.userMarkedSeats.map {
            AutonomousTargetOption(id: $0.id.uuidString, label: "user-marked seat")
        }

        // 最近 5 条对话
        let recentMessages = Array(appModel.chatService.messages.suffix(5))

        // 最近 actions 格式化
        let now = Date()
        let actionsDesc: [String] = recentActions.reversed().map { rec in
            let delta = now.timeIntervalSince(rec.at)
            let label: String
            if delta < 60 { label = "\(Int(delta))s 前" }
            else { label = "\(Int(delta / 60))min 前" }
            return "- \(label)：\(rec.summary)"
        }

        // Context：与 ChatService 同型，但不含 previousInteractionTime（用不到）
        let context = ContextSnapshot(
            now: now,
            activity: appModel.currentActivityDescription,
            scene: appModel.sceneService.summarize()
        )

        do {
            return try await AutonomousDecisionService.decide(
                persona: persona,
                userPersona: appModel.userPersona,
                memory: memory,
                context: context,
                observeTargets: observeTargets,
                seatTargets: seatTargets,
                recentMessages: recentMessages,
                recentActionsDescription: actionsDesc,
                using: llm
            )
        } catch {
            print("⚠️ 自主决策失败：\(error)")
            return nil
        }
    }

    /// 把 LLM 返回的 decision 解析回 rich enum。target_id 不合法时降级 idle / wander。
    private func resolveAction(from decision: AutonomousDecision) -> AutonomousAction {
        switch decision.action {
        case .wander:
            return .wander
        case .idle:
            return .idle
        case .observe:
            if let id = decision.targetID,
               let uuid = UUID(uuidString: id),
               let poi = appModel.sceneService.pointsOfInterest.first(where: { $0.id == uuid }) {
                return .observe(poi)
            }
            print("⚠️ observe target_id 无效，降级 wander")
            return .wander
        case .sit:
            if let id = decision.targetID,
               let uuid = UUID(uuidString: id),
               let seat = appModel.sceneService.userMarkedSeats.first(where: { $0.id == uuid }) {
                return .sit(seat)
            }
            print("⚠️ sit target_id 无效，降级 idle")
            return .idle
        case .initiateTalk:
            let hint = decision.topicHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !hint.isEmpty else {
                print("⚠️ initiate_talk 缺 topic_hint，降级 idle")
                return .idle
            }
            return .initiateTalk(topicHint: hint)
        }
    }

    private func execute(_ action: AutonomousAction) async {
        switch action {
        case .idle:
            return
        case .wander:
            guard let target = pickWanderTarget() else { return }
            // 若当前坐着，先起身再走
            if appModel.isSitting {
                standUpToIdle()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await performWalkToPoint(target: target, faceYaw: nil, validate: false)
        case .observe(let poi):
            guard let (target, yaw) = poiObservationSpot(for: poi) else { return }
            if appModel.isSitting {
                standUpToIdle()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await performWalkToPoint(target: target, faceYaw: yaw, validate: false)
        case .sit(let seat):
            await performSit(at: seat)
        case .initiateTalk(let topicHint):
            await fireAutonomousTopic(topicHint)
        }
    }

    /// initiateTalk：通过 fireProactiveMessage 让 LLM 主动说一段
    private func fireAutonomousTopic(_ topicHint: String) async {
        guard let persona = appModel.currentPersona else { return }
        let userName = appModel.userPersona.name.isEmpty ? "旅行者" : appModel.userPersona.name
        let hint = "你刚刚想到一个话题，主动开口和 \(userName) 聊：\(topicHint)。自然过渡，别像背稿子。"

        let context = ContextSnapshot(
            now: Date(),
            activity: appModel.currentActivityDescription,
            scene: appModel.sceneService.summarize()
        )

        var pendingPerformance: CharacterPersona.AnimationMapping?
        var pendingWalk: WalkTarget?

        let success = await appModel.chatService.fireProactiveMessage(
            promptHint: hint,
            persona: persona,
            userPersona: appModel.userPersona,
            provider: appModel.selectedProvider,
            mode: .spatial,
            context: context
        ) { [weak self] animID, expressionID, walkTargetRaw in
            guard let self else { return }
            if let raw = expressionID, let expr = FacialExpression(rawValue: raw) {
                self.appModel.expressionService.setExpression(expr)
            }
            if let raw = walkTargetRaw, let target = WalkTarget(rawValue: raw) {
                pendingWalk = target
            }
            guard let mapping = persona.animation(forAPIName: animID) else { return }
            if mapping.isPerformance {
                pendingPerformance = mapping
            } else if !mapping.isWalk {
                self.appModel.selectedAnimation = mapping.fileName
            }
        }

        guard success else { return }

        if appModel.isTTSEnabled,
           let last = appModel.chatService.messages.last,
           last.role == .assistant {
            appModel.ttsService.speak(last.text)
            await appModel.ttsService.waitForCompletion()
        }
        if let perf = pendingPerformance {
            await appModel.runPerformance(perf)
        }
        if let walk = pendingWalk {
            await performWalk(walk)
        }
    }

    /// 把执行了的 action 记进 recent ring buffer，给下次决策的 LLM 看
    private func record(action: AutonomousAction) {
        let summary: String
        switch action {
        case .wander:                    summary = "wander"
        case .observe(let poi):          summary = "observe (\(poi.kind == .window ? "window" : "door"))"
        case .sit:                       summary = "sit"
        case .idle:                      summary = "idle"
        case .initiateTalk(let hint):    summary = "initiate_talk (\(hint.prefix(20)))"
        }
        recentActions.append(RecentActionRecord(at: Date(), summary: summary))
        if recentActions.count > AutonomousConfig.recentActionsCapacity {
            recentActions.removeFirst(recentActions.count - AutonomousConfig.recentActionsCapacity)
        }
    }

    /// 给 AutonomousDecisionService 用的 LLM 实例，统一由共享工厂配置。
    private func makeLLMService() throws -> any LLMService {
        try LLMServiceFactory.make(provider: appModel.selectedProvider)
    }

    // MARK: - Autonomous 辅助

    /// 在 floorRegions 里按面积加权挑一块 → 在其 AABB 里随机采样 → 可达性过滤
    private func pickWanderTarget() -> SIMD3<Float>? {
        let floors = appModel.sceneService.floorRegions
        guard !floors.isEmpty else { return nil }
        let anchorPos = appModel.movementService.currentAnchorPosition

        let totalArea = floors.reduce(Float(0)) { $0 + $1.area }
        guard totalArea > 0 else { return nil }

        for _ in 0..<AutonomousConfig.maxSampleAttempts {
            let r = Float.random(in: 0..<totalArea)
            var acc: Float = 0
            var floor: FloorRegion?
            for f in floors {
                acc += f.area
                if r < acc { floor = f; break }
            }
            guard let picked = floor else { continue }

            let xs = picked.polygon.map { $0.x }
            let zs = picked.polygon.map { $0.y }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minZ = zs.min(), let maxZ = zs.max(),
                  maxX > minX, maxZ > minZ else { continue }

            let candidate = SIMD3<Float>(
                Float.random(in: minX...maxX),
                anchorPos.y,
                Float.random(in: minZ...maxZ)
            )

            let flat = simd_distance(
                SIMD2<Float>(candidate.x, candidate.z),
                SIMD2<Float>(anchorPos.x, anchorPos.z)
            )
            if flat < AutonomousConfig.minWanderDistance { continue }

            if case .ok = NavigationService.checkReachability(
                from: anchorPos, to: candidate, scene: appModel.sceneService
            ) {
                return candidate
            }
        }
        return nil
    }

    /// POI 驻足点：沿墙的外法向走 1m 出来，朝向墙面
    private func poiObservationSpot(for poi: PointOfInterest) -> (SIMD3<Float>, Float)? {
        let anchorPos = appModel.movementService.currentAnchorPosition
        let off = SIMD3<Float>(poi.normal.x, 0, poi.normal.z)
        let offLen = simd_length(off)
        guard offLen > 1e-4 else { return nil }
        let unit = off / offLen
        let target = SIMD3<Float>(
            poi.position.x + unit.x * AutonomousConfig.poiStandOffDistance,
            anchorPos.y,
            poi.position.z + unit.z * AutonomousConfig.poiStandOffDistance
        )
        let faceYaw = atan2(-unit.x, -unit.z)

        if case .ok = NavigationService.checkReachability(
            from: anchorPos, to: target, scene: appModel.sceneService
        ) {
            return (target, faceYaw)
        }
        return nil
    }

    /// 按 XZ 距离找最近的用户标记座位
    private func nearestUserMarkedSeat() -> Seat? {
        let seats = appModel.sceneService.userMarkedSeats
        guard !seats.isEmpty else { return nil }
        let p = appModel.movementService.currentAnchorPosition
        return seats.min(by: {
            let dl = ($0.center.x - p.x) * ($0.center.x - p.x) + ($0.center.z - p.z) * ($0.center.z - p.z)
            let dr = ($1.center.x - p.x) * ($1.center.x - p.x) + ($1.center.z - p.z) * ($1.center.z - p.z)
            return dl < dr
        })
    }

    /// 起身：切回第一个"普通 idle"动画（跳过 walk / sit / performance）
    private func standUpToIdle() {
        guard let persona = appModel.currentPersona else { return }
        let idle = persona.animations.first(where: { !$0.isWalk && !$0.isSit && !$0.isPerformance })
            ?? persona.animations.first
        if let idle, idle.fileName != appModel.selectedAnimation {
            appModel.selectedAnimation = idle.fileName
        }
    }

    // MARK: - 通用

    /// 把 yaw 规整到 [-π, π]
    private func normalizeYaw(_ angle: Float) -> Float {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
