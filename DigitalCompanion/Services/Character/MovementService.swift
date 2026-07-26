//
//  MovementService.swift
//  DigitalCompanion
//
//  角色行走编排：
//    - 仅管理"想去哪 / 想转成什么朝向"的目标状态
//    - 每帧的实际插值由 ImmersiveView 完成（它持有 characterAnchor Entity）
//    - ImmersiveView 到达目标时调用 arrive*() 让 async 等待方醒来
//
//  调用流程（AppModel.performWalk 编排）：
//    1. requestYaw(...) → ImmersiveView 每帧把 anchor 旋到目标
//    2. await waitYawArrival()
//    3. AppModel 切 selectedAnimation = 步行
//    4. requestPosition(...) → ImmersiveView 每帧朝目标移动
//    5. await waitPositionArrival()
//    6. AppModel 切回 idle
//    7. （可选）再做一次 requestYaw / waitYawArrival 把朝向复位
//

import Foundation
import simd

@MainActor
@Observable
class MovementService {

    // MARK: - 对外状态

    // 说明：这些字段会在 RealityView.update 闭包里被读和写（notifyXxxArrived 会清它们）。
    // 若让 SwiftUI 观察，就会触发 "Modifying state during view update" 警告；
    // 而且 update 闭包已经由 headPosition 等高频状态驱动在持续 tick，不需要
    // 靠这些字段的变化去触发重跑。所以统一 @ObservationIgnored。

    /// 期望的锚点世界位置（y 由 ImmersiveView 保留当前值）
    @ObservationIgnored private(set) var targetPosition: SIMD3<Float>?
    /// 期望的锚点 yaw（绕 Y 轴，弧度）
    @ObservationIgnored private(set) var targetYaw: Float?

    /// 整条 walk 序列是否进行中（给 ImmersiveView 用来禁用 gaze）
    @ObservationIgnored private(set) var isActive: Bool = false

    /// 由 ImmersiveView 每帧写入：当前锚点世界位置
    @ObservationIgnored var currentAnchorPosition: SIMD3<Float> = SIMD3<Float>(0, 0, -2.0)
    /// 由 ImmersiveView 每帧写入：当前锚点 yaw（弧度）
    @ObservationIgnored var currentAnchorYaw: Float = 0

    // MARK: - 调参

    /// 平移速度（米/秒）
    let moveSpeed: Float = 0.6
    /// 转身速度（弧度/秒）
    let turnSpeed: Float = 3.0
    /// 到达平移目标的阈值
    let arriveDistance: Float = 0.05
    /// 到达转身目标的阈值
    let arriveYaw: Float = 0.05

    // MARK: - 等待

    private var positionContinuation: CheckedContinuation<Void, Never>?
    private var yawContinuation: CheckedContinuation<Void, Never>?

    // MARK: - 生命周期

    /// 标记整条 walk 序列开始（禁用 gaze）
    func begin() {
        isActive = true
    }

    /// 序列结束（恢复 gaze）
    func end() {
        isActive = false
        targetPosition = nil
        targetYaw = nil
    }

    /// 外部打断（切角色 / 清空历史时调用）
    func cancel() {
        // 唤醒挂起的等待方，避免 await 永远不返回
        let pos = positionContinuation
        positionContinuation = nil
        pos?.resume()
        let yaw = yawContinuation
        yawContinuation = nil
        yaw?.resume()
        end()
    }

    // MARK: - 请求 & 等待

    func requestPosition(_ pos: SIMD3<Float>) {
        targetPosition = pos
    }

    func requestYaw(_ yaw: Float) {
        targetYaw = yaw
    }

    /// 等待位置到达；若没有未完成的位置目标，立即返回
    func waitPositionArrival() async {
        guard targetPosition != nil else { return }
        await withCheckedContinuation { cont in
            // 如果上一次等待还没 resume（异常情况），也让它结束
            self.positionContinuation?.resume()
            self.positionContinuation = cont
        }
    }

    /// 等待 yaw 到达
    func waitYawArrival() async {
        guard targetYaw != nil else { return }
        await withCheckedContinuation { cont in
            self.yawContinuation?.resume()
            self.yawContinuation = cont
        }
    }

    // MARK: - ImmersiveView 回调：到达通知

    /// 平移到达
    func notifyPositionArrived() {
        targetPosition = nil
        let cont = positionContinuation
        positionContinuation = nil
        cont?.resume()
    }

    /// 转身到达
    func notifyYawArrived() {
        targetYaw = nil
        let cont = yawContinuation
        yawContinuation = nil
        cont?.resume()
    }
}

// MARK: - 角色行动模式（Phase 4+）

/// 三种模式的语义：
/// - stationary：当前行为（LLM 主动调度 + gaze + push-to-talk）。这是默认态。
/// - follow：跟随用户，保持"侧后方 45°、距离 1m"的管家站位。用户走动时角色自动跟上。
/// - autonomous：自主模式（Phase 6）。角色根据环境和自己的情绪/性格自主行动。
enum MovementMode: String, Sendable, CaseIterable, Identifiable {
    case stationary
    case follow
    case autonomous

    var id: String { rawValue }

    /// 给 UI 的单字简称（3 段式 picker 在窗口底部不占空间）
    var shortLabel: String {
        switch self {
        case .stationary: return "静"
        case .follow:     return "跟"
        case .autonomous: return "自"
        }
    }

    var displayName: String {
        switch self {
        case .stationary: return "静止"
        case .follow:     return "跟随"
        case .autonomous: return "自主"
        }
    }
}

// WalkTarget 原本定义在这里，已迁到 CompanionCore/Models/WalkTarget.swift
// —— 它是 LLM 的 tool schema 一部分，需要和 LLMService 一起跨平台共享。
