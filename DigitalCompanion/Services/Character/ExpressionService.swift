//
//  ExpressionService.swift
//  DigitalCompanion
//
//  表情服务。与 LipSyncService 并列：
//  - 主表情（smile/sad/angry/...）：LLM 选定后锁定，每种表情独立维护 smoothed weight，
//    切换时自动交叉淡入淡出。neutral 表示全部权重归零。
//  - 眨眼（blink）：idle 自发行为，3-6s 随机触发一次，状态机驱动瞬态权重。
//
//  渲染层（ImmersiveView）每帧调用 `tick()` 推进状态，然后读取
//  `expressionWeights` + `blinkWeight`，按预缓存的 shape index 写入 BlendShapeWeights。
//

import Foundation
import CompanionCore

@MainActor
@Observable
class ExpressionService {

    // MARK: - 对外状态（渲染层读取）

    /// 当前 LLM 锁定的主表情（切换时其它表情在自动淡出）
    private(set) var currentExpression: FacialExpression = .neutral

    /// 每种表情当前平滑后的权重（0-1）
    /// - 切换后：新表情的 weight 向 1 逼近，其他的向 0 逼近
    /// - 渲染层直接用这个 dict 写入 BlendShape
    private(set) var expressionWeights: [FacialExpression: Float] = [:]

    /// 眨眼瞬态权重（0-1），独立于主表情通道
    private(set) var blinkWeight: Float = 0

    /// 是否启用 idle 眨眼（某些角色模型常态就是闭眼的，应禁用）
    var isBlinkEnabled: Bool = true

    // MARK: - 参数

    /// 主表情淡入/淡出时间常数（秒）；越小切得越快
    private let fadeTau: Float = 0.1

    /// 眨眼节奏
    private let blinkIntervalRange: ClosedRange<Double> = 3.0...6.0
    private let blinkCloseDuration: Double = 0.04   // 闭眼 40ms
    private let blinkHoldDuration:  Double = 0.05   // 完全闭合 50ms
    private let blinkOpenDuration:  Double = 0.10   // 睁眼 100ms

    /// 主表情达到"锁定"的最大权重（可以 <1 避免表情太夸张）
    private let maxExpressionIntensity: Float = 1.0

    /// wink 是瞬态表情（俏皮眨一下），持续 ~1s 后自动回到之前的表情
    /// 持续时间包含淡入 + 保持（淡出由 setExpression 触发后 tau 控制）
    private let winkAutoRevertDelay: TimeInterval = 1.0

    // MARK: - 内部状态

    private var lastTickTime: Date?

    private enum BlinkPhase { case idle, closing, holding, opening }
    private var blinkPhase: BlinkPhase = .idle
    private var nextBlinkAt: Date?
    private var blinkPhaseStartedAt: Date?

    /// wink 期间记录之前的表情，过期后自动 revert
    private var preWinkExpression: FacialExpression = .neutral
    private var winkStartedAt: Date?

    // MARK: - 初始化

    init() {
        // 所有表情 weight 默认 0
        for e in FacialExpression.allCases {
            expressionWeights[e] = 0
        }
        scheduleNextBlink(from: Date())
    }

    // MARK: - 对外 API

    /// LLM 或手动切换主表情。设为 neutral 等价于"所有表情淡出到 0"。
    /// wink 是瞬态事件：触发后 ~1s 自动回到之前的表情。
    func setExpression(_ e: FacialExpression) {
        // wink 期间再次点 wink：重置 timer（再眨一次）
        if e == .wink && currentExpression == .wink {
            winkStartedAt = Date()
            return
        }
        guard currentExpression != e else { return }
        // print("😊 表情切换: \(currentExpression.rawValue) → \(e.rawValue)")

        if e == .wink {
            preWinkExpression = currentExpression  // 记录当前，用于稍后 revert
            winkStartedAt = Date()
        } else {
            winkStartedAt = nil                     // 切别的 → 取消 wink timer
        }
        currentExpression = e
    }

    /// 每帧由渲染层调用：推进主表情 fade + 眨眼状态机
    func tick() {
        let now = Date()
        let dt: TimeInterval
        if let last = lastTickTime {
            dt = max(0, now.timeIntervalSince(last))
        } else {
            dt = 1.0 / 90.0
        }
        lastTickTime = now

        updateWinkAutoRevert(now: now)
        updateExpressionFade(dt: Float(dt))
        updateBlink(now: now)
    }

    /// 切角色 / 退出时清空
    func stop() {
        currentExpression = .neutral
        for e in FacialExpression.allCases {
            expressionWeights[e] = 0
        }
        blinkWeight = 0
        blinkPhase = .idle
        blinkPhaseStartedAt = nil
        winkStartedAt = nil
        preWinkExpression = .neutral
        lastTickTime = nil
        scheduleNextBlink(from: Date())
    }

    // MARK: - Wink 瞬态自动 revert

    private func updateWinkAutoRevert(now: Date) {
        guard currentExpression == .wink,
              let start = winkStartedAt,
              now.timeIntervalSince(start) > winkAutoRevertDelay else { return }
        let revert = preWinkExpression
        // print("😉 wink 自动结束 → \(revert.rawValue)")
        winkStartedAt = nil
        currentExpression = revert   // 不走 setExpression（避免覆盖 preWinkExpression）
    }

    // MARK: - 主表情淡入淡出

    /// 每种表情的目标权重：当前锁定的 = max，其余 = 0。
    /// 用 exp-based lerp 逼近目标，dt-aware（掉帧时不会抖）
    private func updateExpressionFade(dt: Float) {
        guard dt > 0 else { return }
        let lerp = 1 - expf(-dt / fadeTau)

        for e in FacialExpression.allCases {
            let target: Float = (e == currentExpression && e != .neutral) ? maxExpressionIntensity : 0
            let current = expressionWeights[e] ?? 0
            let next = current + (target - current) * lerp
            expressionWeights[e] = next
        }
    }

    // MARK: - 眨眼状态机

    private func scheduleNextBlink(from base: Date) {
        let delay = Double.random(in: blinkIntervalRange)
        nextBlinkAt = base.addingTimeInterval(delay)
    }

    private func updateBlink(now: Date) {
        // 角色禁用 blink（比如常态闭眼）—— 权重固定 0，状态机冻结在 idle
        guard isBlinkEnabled else {
            blinkWeight = 0
            blinkPhase = .idle
            blinkPhaseStartedAt = nil
            return
        }

        switch blinkPhase {
        case .idle:
            blinkWeight = 0
            if let next = nextBlinkAt, now >= next {
                blinkPhase = .closing
                blinkPhaseStartedAt = now
            }

        case .closing:
            let t = phaseProgress(now: now, duration: blinkCloseDuration)
            blinkWeight = Float(t)
            if t >= 1 {
                blinkPhase = .holding
                blinkPhaseStartedAt = now
            }

        case .holding:
            blinkWeight = 1
            let t = phaseProgress(now: now, duration: blinkHoldDuration)
            if t >= 1 {
                blinkPhase = .opening
                blinkPhaseStartedAt = now
            }

        case .opening:
            let t = phaseProgress(now: now, duration: blinkOpenDuration)
            blinkWeight = Float(1 - t)
            if t >= 1 {
                blinkWeight = 0
                blinkPhase = .idle
                blinkPhaseStartedAt = nil
                scheduleNextBlink(from: now)
            }
        }
    }

    private func phaseProgress(now: Date, duration: TimeInterval) -> Double {
        guard let start = blinkPhaseStartedAt, duration > 0 else { return 1 }
        return min(1, now.timeIntervalSince(start) / duration)
    }
}
