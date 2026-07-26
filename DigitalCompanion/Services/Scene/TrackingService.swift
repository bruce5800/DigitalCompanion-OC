//
//  TrackingService.swift
//  DigitalCompanion
//
//  Created by 李卓伦 on 2026/4/12.
//

import ARKit
import RealityKit
import QuartzCore  // for CACurrentMediaTime
import simd

/// 手势类型
enum HandGestureType: String {
    case wave = "挥手"
    case thumbsUp = "竖大拇指"
    case openPalm = "张开手掌"
    case push = "推手"
    case none = "无"
}

/// ARKit 追踪服务：头部位置 + 手势识别
@MainActor
@Observable
class TrackingService {

    /// 用户头部在世界坐标中的位置
    var headPosition: SIMD3<Float> = .zero

    /// 用户头部在 XZ 水平面上的朝向（弧度，绕 Y）——用 atan2(forward.x, forward.z) 归一化得到
    /// Follow 模式需要用这个算"用户侧后方 45°"的站位。
    /// 值域 [-π, π]；无追踪时为 0。
    var headYaw: Float = 0

    /// 当前检测到的手势
    var detectedGesture: HandGestureType = .none

    /// 握拳持续态（右手）。每帧更新，外部监听上升/下降沿做 push-to-talk。
    /// 独立于 `detectedGesture` 的 cooldown 单次触发机制。
    var isFistHeld: Bool = false

    /// 追踪是否正在运行
    var isTracking = false

    private var arSession = ARKitSession()
    private var worldTracking = WorldTrackingProvider()
    private var handTracking = HandTrackingProvider()

    // 手势防抖
    private var lastGestureTime: Date = .distantPast
    private let gestureCooldown: TimeInterval = 2.0

    /// 看门狗用：最近一次"右手被追踪到"的时刻。握拳时若右手移出视野，
    /// anchorUpdates 不再投递，isFistHeld 会卡在 true（麦克风一直开），用它做超时复位。
    private var lastRightHandSeen: Date = .distantPast

    // —— 握拳调试 ——
    /// true 时每 ~300ms 打印一次握拳各项数值；稳定后可关闭
    var fistDebugVerbose: Bool = false
    private var lastFistDebugLog: Date = .distantPast
    private let fistDebugInterval: TimeInterval = 0.3

    // MARK: - 启动追踪

    func startTracking() async {
        // 按设备能力选择支持的 providers（模拟器不支持手势追踪）
        var providers: [DataProvider] = []
        if WorldTrackingProvider.isSupported {
            providers.append(worldTracking)
        } else {
            print("⚠️ WorldTrackingProvider 在当前设备不可用")
        }

        let handSupported = HandTrackingProvider.isSupported
        if handSupported {
            providers.append(handTracking)
        } else {
            print("⚠️ HandTrackingProvider 在当前设备不可用（模拟器不支持手势识别）")
        }

        guard !providers.isEmpty else {
            print("❌ 当前设备不支持任何 ARKit Provider，追踪未启动")
            isTracking = false
            return
        }

        do {
            try await arSession.run(providers)
            isTracking = true
            print("✅ ARKit 追踪已启动")

            if handSupported {
                async let headTask: () = processHeadTracking()
                async let handTask: () = processHandTracking()
                async let fistWatch: () = fistWatchdog()
                _ = await (headTask, handTask, fistWatch)
            } else {
                // 仅头部追踪
                await processHeadTracking()
            }
        } catch {
            print("❌ ARKit 启动失败: \(error)")
            isTracking = false
        }
    }

    func stopTracking() {
        arSession.stop()
        isTracking = false
        detectedGesture = .none
        isFistHeld = false
    }

    // MARK: - 头部追踪

    private func processHeadTracking() async {
        while isTracking {
            guard worldTracking.state == .running else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }

            if let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                let transform = deviceAnchor.originFromAnchorTransform
                headPosition = SIMD3<Float>(
                    transform.columns.3.x,
                    transform.columns.3.y,
                    transform.columns.3.z
                )
                // 设备本地 -Z 是观察方向（OpenGL/visionOS 约定），取其水平分量作 headYaw
                let fx = -transform.columns.2.x
                let fz = -transform.columns.2.z
                if fx * fx + fz * fz > 1e-6 {
                    headYaw = atan2(fx, fz)
                }
            }

            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    // MARK: - 手部追踪

    private func processHandTracking() async {
        for await update in handTracking.anchorUpdates {
            guard isTracking else { break }

            let hand = update.anchor
            guard hand.chirality == .right else { continue }

            // 右手丢失追踪 → 握拳态复位（防止松手时手离开 FOV 卡住）
            guard hand.isTracked, let handSkeleton = hand.handSkeleton else {
                if isFistHeld { isFistHeld = false }
                continue
            }
            lastRightHandSeen = Date()   // 看门狗用：右手当前可追踪

            // —— 握拳：每帧更新持续态，用于 push-to-talk ——
            let fist = detectFist(skeleton: handSkeleton, hand: hand)
            if fist != isFistHeld {
                isFistHeld = fist
                print("✊ 握拳状态: \(fist ? "按下" : "松开")")
            }

            // —— 其它手势：走原有的 cooldown + 单次触发 ——
            let gesture = recognizeGesture(skeleton: handSkeleton, hand: hand)

            if gesture != .none {
                let now = Date()
                if now.timeIntervalSince(lastGestureTime) >= gestureCooldown {
                    detectedGesture = gesture
                    lastGestureTime = now
                    // print("🤚 检测到手势: \(gesture.rawValue)")

                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if self.detectedGesture == gesture {
                            self.detectedGesture = .none
                        }
                    }
                }
            }
        }
    }

    /// 看门狗：握拳期间右手若超过 ~0.4s 没有任何 tracked 更新（移出视野/追踪中断），
    /// anchorUpdates 不会再投递 isTracked=false，isFistHeld 会卡在 true、麦克风一直开。
    /// 这里兜底复位（相当于松开 push-to-talk）。ImmersiveView 的 onChange(isFistHeld)
    /// 会随之触发 stopListening。
    private func fistWatchdog() async {
        while isTracking {
            try? await Task.sleep(for: .milliseconds(200))
            if isFistHeld && Date().timeIntervalSince(lastRightHandSeen) > 0.4 {
                isFistHeld = false
                print("✊ 握拳状态: 松开（看门狗：右手追踪丢失）")
            }
        }
    }

    /// 握拳检测：五指全部蜷曲 + 拇指包拳心。调试阶段以比值形式打印各项数值。
    /// 注意：用 unchecked 版本取关节，握拳时被遮挡的指尖仍使用预测位姿。
    private func detectFist(skeleton: HandSkeleton, hand: HandAnchor) -> Bool {
        let wrist         = jointWorldPosUnchecked(.wrist,              skeleton: skeleton, hand: hand)
        let thumbTip      = jointWorldPosUnchecked(.thumbTip,           skeleton: skeleton, hand: hand)
        let indexTip      = jointWorldPosUnchecked(.indexFingerTip,     skeleton: skeleton, hand: hand)
        let middleTip     = jointWorldPosUnchecked(.middleFingerTip,    skeleton: skeleton, hand: hand)
        let ringTip       = jointWorldPosUnchecked(.ringFingerTip,      skeleton: skeleton, hand: hand)
        let littleTip     = jointWorldPosUnchecked(.littleFingerTip,    skeleton: skeleton, hand: hand)
        let indexKnuckle  = jointWorldPosUnchecked(.indexFingerKnuckle, skeleton: skeleton, hand: hand)
        let middleKnuckle = jointWorldPosUnchecked(.middleFingerKnuckle,skeleton: skeleton, hand: hand)
        let ringKnuckle   = jointWorldPosUnchecked(.ringFingerKnuckle,  skeleton: skeleton, hand: hand)
        let littleKnuckle = jointWorldPosUnchecked(.littleFingerKnuckle,skeleton: skeleton, hand: hand)

        // —— 阈值（调试时想试不同值改这两行即可）——
        // 手指完全伸直 ≈ 1.7~1.8；自然弯 ≈ 1.2~1.4；握紧 ≈ 0.9~1.1
        let curlThreshold: Float = 1.4
        // 拇指到指节距离（米）
        let thumbThreshold: Float = 0.06

        // —— 蜷曲判据：比值 = tip到wrist / knuckle到wrist ——
        let indexRatio  = simd_distance(indexTip,  wrist) / max(simd_distance(indexKnuckle,  wrist), 0.001)
        let middleRatio = simd_distance(middleTip, wrist) / max(simd_distance(middleKnuckle, wrist), 0.001)
        let ringRatio   = simd_distance(ringTip,   wrist) / max(simd_distance(ringKnuckle,   wrist), 0.001)
        let littleRatio = simd_distance(littleTip, wrist) / max(simd_distance(littleKnuckle, wrist), 0.001)

        let indexCurled  = indexRatio  < curlThreshold
        let middleCurled = middleRatio < curlThreshold
        let ringCurled   = ringRatio   < curlThreshold
        let littleCurled = littleRatio < curlThreshold

        // —— 拇指贴近食/中指指节 ——
        let thumbToIndexK  = simd_distance(thumbTip, indexKnuckle)
        let thumbToMiddleK = simd_distance(thumbTip, middleKnuckle)
        let thumbTucked = thumbToIndexK < thumbThreshold || thumbToMiddleK < thumbThreshold

        let isFist = indexCurled && middleCurled && ringCurled && littleCurled && thumbTucked

        if fistDebugVerbose {
            logFistDebug(
                isFist: isFist,
                indexRatio: indexRatio, middleRatio: middleRatio,
                ringRatio: ringRatio, littleRatio: littleRatio,
                curlThreshold: curlThreshold,
                thumbToIndex: thumbToIndexK, thumbToMiddle: thumbToMiddleK,
                thumbThreshold: thumbThreshold
            )
        }

        return isFist
    }

    /// 限频打印握拳诊断。稳定后把 fistDebugVerbose 设 false 即可停止输出。
    /// 示例：🖐️[FIST=✗] idx=1.42✗ mid=1.38✗ rng=1.25✓ lit=1.20✓ | thm→i=0.082✓ thm→m=0.074✓ | fail=i,m
    private func logFistDebug(
        isFist: Bool,
        indexRatio: Float, middleRatio: Float, ringRatio: Float, littleRatio: Float,
        curlThreshold: Float,
        thumbToIndex: Float, thumbToMiddle: Float, thumbThreshold: Float
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastFistDebugLog) >= fistDebugInterval else { return }
        lastFistDebugLog = now

        func mark(_ pass: Bool) -> String { pass ? "✓" : "✗" }
        var fails: [String] = []
        if indexRatio  >= curlThreshold { fails.append("idx") }
        if middleRatio >= curlThreshold { fails.append("mid") }
        if ringRatio   >= curlThreshold { fails.append("rng") }
        if littleRatio >= curlThreshold { fails.append("lit") }
        let thumbOK = thumbToIndex < thumbThreshold || thumbToMiddle < thumbThreshold
        if !thumbOK { fails.append("thm") }

        let line = String(
            format: "🖐️[FIST=%@] idx=%.2f%@ mid=%.2f%@ rng=%.2f%@ lit=%.2f%@ | thm→i=%.3f thm→m=%.3f %@ | fail=%@",
            isFist ? "✓" : "✗",
            indexRatio, mark(indexRatio < curlThreshold),
            middleRatio, mark(middleRatio < curlThreshold),
            ringRatio, mark(ringRatio < curlThreshold),
            littleRatio, mark(littleRatio < curlThreshold),
            thumbToIndex, thumbToMiddle, mark(thumbOK),
            fails.isEmpty ? "-" : fails.joined(separator: ",")
        )
        print(line)
    }

    private func logFistDebug(message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastFistDebugLog) >= fistDebugInterval else { return }
        lastFistDebugLog = now
        print("🖐️[FIST] \(message)")
    }

    /// 手势识别
    private func recognizeGesture(skeleton: HandSkeleton, hand: HandAnchor) -> HandGestureType {
        guard let thumbTip = jointWorldPos(.thumbTip, skeleton: skeleton, hand: hand),
              let indexTip = jointWorldPos(.indexFingerTip, skeleton: skeleton, hand: hand),
              let middleTip = jointWorldPos(.middleFingerTip, skeleton: skeleton, hand: hand),
              let ringTip = jointWorldPos(.ringFingerTip, skeleton: skeleton, hand: hand),
              let littleTip = jointWorldPos(.littleFingerTip, skeleton: skeleton, hand: hand),
              let wrist = jointWorldPos(.wrist, skeleton: skeleton, hand: hand),
              let indexKnuckle = jointWorldPos(.indexFingerKnuckle, skeleton: skeleton, hand: hand),
              let middleKnuckle = jointWorldPos(.middleFingerKnuckle, skeleton: skeleton, hand: hand)
        else { return .none }

        let indexExtended = simd_distance(indexTip, wrist) > simd_distance(indexKnuckle, wrist) * 1.2
        let middleExtended = simd_distance(middleTip, wrist) > simd_distance(middleKnuckle, wrist) * 1.2

        // 竖大拇指
        let thumbUp = thumbTip.y > wrist.y + 0.06
        let fingersCurled = !indexExtended && !middleExtended
        if thumbUp && fingersCurled {
            return .thumbsUp
        }

        // 张开手掌
        let allTipsAbove = indexTip.y > wrist.y && middleTip.y > wrist.y
            && ringTip.y > wrist.y && littleTip.y > wrist.y
        let fingerSpread = simd_distance(indexTip, littleTip) > 0.06
        if allTipsAbove && fingerSpread && indexExtended && middleExtended {
            // 推手：手掌张开 + 手腕显著前伸（超过头部 25cm），视为"推开"
            // 角色在 -Z 方向，所以 wrist.z 明显小于 headPosition.z 就是"朝前推"
            // 判断次序：先看是不是在推，再退化为 wave / openPalm
            let armExtendedForward = (headPosition.z - wrist.z) > 0.25
            let handBelowHead = wrist.y < headPosition.y
            if armExtendedForward && handBelowHead {
                return .push
            }

            // 挥手：手掌张开 + 手高于头部
            let handAboveHead = wrist.y > headPosition.y - 0.1
            if handAboveHead {
                return .wave
            }
            return .openPalm
        }

        return .none
    }

    /// 获取关节世界坐标（要求该关节本身处于 tracked 状态）
    private func jointWorldPos(_ jointName: HandSkeleton.JointName, skeleton: HandSkeleton, hand: HandAnchor) -> SIMD3<Float>? {
        let joint = skeleton.joint(jointName)
        guard joint.isTracked else { return nil }
        let world = hand.originFromAnchorTransform * joint.anchorFromJointTransform
        return SIMD3<Float>(world.columns.3.x, world.columns.3.y, world.columns.3.z)
    }

    /// 获取关节世界坐标（忽略 joint.isTracked——使用最近的预测位姿）
    /// 握拳时指尖会被掌心遮挡，个别关节的 isTracked 会变 false，
    /// 但其 transform 仍包含预测位姿，足够做整体姿势判定。
    /// 外层仍要求 `hand.isTracked == true`（整只手还在 FOV 内）。
    private func jointWorldPosUnchecked(_ jointName: HandSkeleton.JointName, skeleton: HandSkeleton, hand: HandAnchor) -> SIMD3<Float> {
        let joint = skeleton.joint(jointName)
        let world = hand.originFromAnchorTransform * joint.anchorFromJointTransform
        return SIMD3<Float>(world.columns.3.x, world.columns.3.y, world.columns.3.z)
    }
}
