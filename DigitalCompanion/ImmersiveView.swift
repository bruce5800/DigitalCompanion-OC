//
//  ImmersiveView.swift
//  DigitalCompanion
//
//  Created by 李卓伦 on 2026/3/28.
//

import SwiftUI
import RealityKit
import RealityKitContent
import ARKit
import Combine
import CompanionCore

struct ImmersiveView: View {

    @Environment(AppModel.self) private var appModel

    /// 当前已加载的动画 fileName（用于避免重复加载）
    @State private var loadedAnimationName: String = ""

    /// 上一次处理的手势
    @State private var lastHandledGesture: HandGestureType = .none

    /// 是否正在切换模型（防止并发加载）
    @State private var isSwitching = false

    /// 当前角色上带 blend shapes 的 ModelEntity（用于口型同步）
    @State private var lipSyncTarget: ModelEntity?

    /// 口型 blend shape 的缓存索引（避免每帧字符串查找）
    @State private var mouthShapeIndex: Int?
    @State private var visemeIndices: [Viseme: Int] = [:]
    @State private var expressionIndices: [FacialExpression: Int] = [:]
    @State private var blinkIndex: Int?
    @State private var lipSyncDataID: String?
    @State private var visemeWeightStore = VisemeWeightStore()

    /// 每帧订阅句柄
    @State private var frameSubscription: (any Cancellable)?
    @State private var tickCounter = FrameTickCounter()

    /// 移动/转身子步进的时间基准（上一帧时间戳）。用引用类型 box，避免在
    /// RealityView.update 闭包里写 @State 触发 SwiftUI 警告。
    @State private var moveClock = MoveClock()

    /// 场景可视化 renderer（Phase 2 调试）——持有 plane → ModelEntity 的镜像字典，
    /// 每次 sceneService 变化时做增量 diff。
    @State private var sceneOverlay = SceneOverlayRenderer()

    var body: some View {
        RealityView { content in
            // 创建根锚点
            let anchor = Entity()
            anchor.name = "characterAnchor"
            #if DEBUG
            // 截图演示：人物站在聊天窗右侧，避免遮住对话内容。
            let screenshotLayout = ScreenshotDemoData.isEnabled
                && ["immersive", "gesture-guide", "movement"].contains(ScreenshotDemoData.route ?? "")
            anchor.position = SIMD3<Float>(screenshotLayout ? 0.85 : 0, 0, -2.0)
            #else
            anchor.position = SIMD3<Float>(0, 0, -2.0)
            #endif
            content.add(anchor)

            // 场景可视化的 overlay 根（Phase 2 调试专用）
            // 放在世界系原点，所有 plane entity 都挂它下面，方便整体显示/隐藏
            let overlayRoot = Entity()
            overlayRoot.name = "sceneOverlayRoot"
            content.add(overlayRoot)

            // 正面主光
            let frontLight = Entity()
            var frontLightComp = DirectionalLightComponent()
            frontLightComp.intensity = 800
            frontLightComp.color = .white
            frontLight.components.set(frontLightComp)
            frontLight.position = SIMD3<Float>(0, 2.0, 1.0)
            frontLight.look(at: SIMD3<Float>(0, 1.0, -2.0), from: frontLight.position, relativeTo: nil)
            content.add(frontLight)

            // 补光
            let fillLight = Entity()
            var fillLightComp = DirectionalLightComponent()
            fillLightComp.intensity = 400
            fillLightComp.color = .init(white: 0.9, alpha: 1.0)
            fillLight.components.set(fillLightComp)
            fillLight.position = SIMD3<Float>(-2.0, 1.5, 0)
            fillLight.look(at: SIMD3<Float>(0, 1.0, -2.0), from: fillLight.position, relativeTo: nil)
            content.add(fillLight)

            // 加载默认动画
            await loadAndAttach(fileName: appModel.selectedAnimation, to: anchor)
            loadedAnimationName = appModel.selectedAnimation

            // 启动 ARKit 追踪
            Task {
                await appModel.trackingService.startTracking()
            }
        } update: { content in
            guard let anchor = content.entities.first(where: { $0.name == "characterAnchor" }) else {
                return
            }
            let overlayRoot = content.entities.first(where: { $0.name == "sceneOverlayRoot" })

            // 场景可视化（Phase 2 调试）——这里读 sceneService 的数组也会建立观察依赖，
            // 每次 plane 更新 SwiftUI 会自动重跑这个闭包，renderer 做增量 diff
            if let overlayRoot {
                sceneOverlay.sync(
                    from: appModel.sceneService,
                    enabled: appModel.isSceneVisualizationEnabled,
                    to: overlayRoot
                )
            }

            // 动画切换
            let targetName = appModel.selectedAnimation
            if loadedAnimationName != targetName && !isSwitching {
                let fileName = targetName
                Task {
                    isSwitching = true
                    loadedAnimationName = fileName
                    await loadAndAttach(fileName: fileName, to: anchor)
                    isSwitching = false
                }
            }

            // 强制读一下 headPosition，建立对它的 SwiftUI 观察依赖。
            // 走位期间 gaze 被禁用，若不做这步 update 就不再被 ARKit 头部位姿
            // 驱动重跑，走位会降到 ~2Hz（看上去"原地踏步没走"）。
            _ = appModel.trackingService.headPosition

            // 走位优先：每帧朝 MovementService 的目标平移 / 转身
            // isActive 期间 gaze 让位，避免两路旋转打架
            updateMovement(anchor: anchor)

            // 目光跟随（走位期间禁用；坐姿期间也禁用——否则角色会在椅子上旋转）
            if appModel.trackingService.isTracking
                && !appModel.movementService.isActive
                && !appModel.isSitting {
                updateGaze(anchor: anchor)
            }

            // 把当前锚点位姿汇报给 MovementService，供 AppModel 计算目标
            appModel.movementService.currentAnchorPosition = anchor.position
            appModel.movementService.currentAnchorYaw = extractYRotation(from: anchor.transform.rotation)

            // 手势响应
            let gesture = appModel.trackingService.detectedGesture
            if gesture != .none && gesture != lastHandledGesture {
                let g = gesture
                Task {
                    lastHandledGesture = g
                    handleGesture(g)
                }
            } else if gesture == .none && lastHandledGesture != .none {
                Task {
                    lastHandledGesture = .none
                }
            }
        }
        .gesture(
            TapGesture().targetedToAnyEntity().onEnded { _ in
                // 从当前角色的动画列表中随机选一个
                guard let persona = appModel.currentPersona else { return }
                let others = persona.animations.filter { $0.fileName != appModel.selectedAnimation }
                if let random = others.randomElement() {
                    appModel.selectedAnimation = random.fileName
                }
            }
        )
        .onDisappear {
            appModel.trackingService.stopTracking()
        }
        // 握拳 push-to-talk：用 onChange 而不是 RealityView.update 里读状态，
        // 因为 update 闭包不保证对每次 @Observable 变化都重跑（尤其是非场景相关的状态）
        .onChange(of: appModel.trackingService.isFistHeld) { _, fistNow in
            if fistNow {
                // 录音和 TTS 同时开会自激 → 先打断 TTS
                appModel.ttsService.stop()
                Task { await appModel.speechService.startListening() }
            } else {
                appModel.speechService.stopListening()
            }
        }
    }

    // MARK: - 加载并挂载角色

    private func loadAndAttach(fileName: String, to anchor: Entity) async {
        guard let character = await appModel.loadModel(fileName: fileName) else {
            print("❌ 无法加载 \(fileName)")
            return
        }

        character.scale = SIMD3<Float>(repeating: 1.0)
        character.generateCollisionShapes(recursive: true)
        character.components.set(InputTargetComponent())

        // 移除旧模型
        for child in anchor.children {
            child.removeFromParent()
        }

        anchor.addChild(character)

        let displayName = appModel.currentPersona?.animations.first(where: { $0.fileName == fileName })?.displayName ?? fileName
        playAnimations(on: character, name: displayName)

        // 通知 AppModel：该动画已经挂到场景并开始播放。
        // performWalk 等在这个信号上，确保走路动画起来后才开始平移。
        appModel.notifyAnimationAttached(fileName)

        // 为角色主网格挂载 BlendShapeWeightsComponent，用于口型同步
        let target = setupLipSync(on: character)
        lipSyncTarget = target

        // 订阅 SceneEvents.Update：在每帧动画采样之后写入权重
        let hasBlendShapes = !visemeIndices.isEmpty
            || mouthShapeIndex != nil
            || !expressionIndices.isEmpty
            || blinkIndex != nil
        if let target, let dataID = lipSyncDataID, let scene = target.scene, hasBlendShapes {
            frameSubscription?.cancel()
            let lipSyncSvc = appModel.lipSyncService
            let exprSvc = appModel.expressionService
            let counter = tickCounter
            let visemeIdxs = visemeIndices
            let exprIdxs = expressionIndices
            let blinkIdx = blinkIndex
            let fallbackIdx = mouthShapeIndex
            let store = visemeWeightStore
            let lerpSpeed: Float = 0.35

            frameSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak target] _ in
                guard let target else { return }

                // 推进表情状态机（主表情 fade + 眨眼 timer）
                exprSvc.tick()

                let openness = lipSyncSvc.mouthOpenness
                let viseme = lipSyncSvc.currentViseme
                let exprWeights = exprSvc.expressionWeights
                let blinkW = exprSvc.blinkWeight

                guard var comp = target.components[BlendShapeWeightsComponent.self],
                      var data = comp.weightSet[dataID] ?? comp.weightSet.first else { return }

                // ----- Viseme（口型）-----
                if !visemeIdxs.isEmpty {
                    for v in Viseme.vowels {
                        guard let idx = visemeIdxs[v], idx < data.weights.count else { continue }
                        let targetW: Float = (v == viseme) ? openness : 0
                        let current = store.weight(for: v)
                        let next = current + (targetW - current) * lerpSpeed
                        store.setWeight(next, for: v)
                        data.weights[idx] = next
                    }
                } else if let idx = fallbackIdx, idx < data.weights.count {
                    data.weights[idx] = openness
                }

                // ----- Expression（主表情）-----
                // service 已做平滑，每帧直接写
                for (e, idx) in exprIdxs {
                    guard idx < data.weights.count else { continue }
                    data.weights[idx] = exprWeights[e] ?? 0
                }

                // ----- Blink（眨眼 idle）-----
                if let bi = blinkIdx, bi < data.weights.count {
                    data.weights[bi] = blinkW
                }

                comp.weightSet.set(data)
                target.components.set(comp)

                counter.tick { n in
                    if n % 60 == 1 {
                        let _ = viseme?.rawValue ?? "-"
                        // print("👄 frame#\(n) viseme=\(vName) openness=\(openness) expr=\(exprSvc.currentExpression.rawValue) blink=\(blinkW)")
                    }
                }
            }
            // print("✅ BlendShape 订阅已注册：viseme=\(visemeIndices.count), expr=\(expressionIndices.count), blink=\(blinkIndex != nil), dataID=\(dataID)")
            _ = dataID
        } else {
            frameSubscription = nil
            print("⚠️ BlendShape 订阅失败：target=\(target != nil), viseme=\(visemeIndices.count), expr=\(expressionIndices.count), blink=\(blinkIndex != nil), scene=\(target?.scene != nil)")
        }
    }

    // MARK: - 口型同步挂载

    private func setupLipSync(on character: Entity) -> ModelEntity? {
        var allModelEntities: [ModelEntity] = []
        Self.collectModelEntities(from: character, into: &allModelEntities)

        for modelEntity in allModelEntities {
            guard let mesh = modelEntity.model?.mesh else { continue }
            let mapping = BlendShapeWeightsMapping(meshResource: mesh)
            let component = BlendShapeWeightsComponent(weightsMapping: mapping)
            modelEntity.components.set(component)

            if let comp = modelEntity.components[BlendShapeWeightsComponent.self],
               !comp.weightSet.isEmpty,
               let data = comp.weightSet.first {

                let names = data.weightNames
                // print("👄 口型同步挂载到 \(modelEntity.name)，共 \(names.count) 个 blend shapes")
                // print("   weightSet count: \(comp.weightSet.count)，data.id: \(data.id)")
                // print("   前 10 个名字: \(names.prefix(10).joined(separator: ", "))")

                // ----- 扫描 Viseme 索引 -----
                var mapping: [Viseme: Int] = [:]
                let jpNames: [Viseme: String] = [.a: "あ", .i: "い", .u: "う", .e: "え", .o: "お"]
                for v in Viseme.vowels {
                    let shapeName = v.shapeName
                    let jp = jpNames[v] ?? ""
                    if let idx = names.firstIndex(where: { n in
                        n == shapeName
                            || n.hasSuffix("." + shapeName)
                            || n.hasSuffix("/" + shapeName)
                            || n == jp
                    }) {
                        mapping[v] = idx
                        // print("   ✅ viseme \(v.rawValue) → [\(idx)] \(names[idx])")
                    } else {
                        // print("   ⚠️ 未找到 viseme \(v.rawValue) (\(shapeName))")
                        _ = shapeName
                    }
                }

                // ----- 扫描 Expression 索引（neutral 跳过，没有对应 shape）-----
                var exprMapping: [FacialExpression: Int] = [:]
                for e in FacialExpression.allCases {
                    guard let shapeName = e.shapeName else { continue }
                    if let idx = names.firstIndex(where: { n in
                        n == shapeName
                            || n.hasSuffix("." + shapeName)
                            || n.hasSuffix("/" + shapeName)
                    }) {
                        exprMapping[e] = idx
                        // print("   ✅ expr \(e.rawValue) → [\(idx)] \(names[idx])")
                    } else {
                        // print("   ⚠️ 未找到 expr \(e.rawValue) (\(shapeName))")
                        _ = shapeName
                    }
                }

                // ----- 扫描 Blink 索引 -----
                var blinkIdx: Int? = nil
                let blinkName = BlinkShape.name
                if let idx = names.firstIndex(where: { n in
                    n == blinkName
                        || n.hasSuffix("." + blinkName)
                        || n.hasSuffix("/" + blinkName)
                }) {
                    blinkIdx = idx
                    // print("   ✅ blink → [\(idx)] \(names[idx])")
                } else {
                    // print("   ⚠️ 未找到 blink shape (\(blinkName))")
                }

                visemeIndices = mapping
                expressionIndices = exprMapping
                blinkIndex = blinkIdx
                visemeWeightStore.reset()
                lipSyncDataID = data.id
                mouthShapeIndex = mapping[.a] ?? 0
                return modelEntity
            } else {
                modelEntity.components.remove(BlendShapeWeightsComponent.self)
            }
        }
        print("⚠️ 未找到带 blend shapes 的 mesh，口型同步不可用")
        return nil
    }

    private static func collectModelEntities(from entity: Entity, into out: inout [ModelEntity]) {
        if let m = entity as? ModelEntity, m.model != nil {
            out.append(m)
        }
        for child in entity.children {
            collectModelEntities(from: child, into: &out)
        }
    }

    // MARK: - 播放动画

    private func playAnimations(on character: Entity, name: String) {
        let allAnimations = Self.findAllAnimations(in: character)
        if allAnimations.isEmpty {
            print("⚠️ \(name) 没有内嵌动画")
        } else {
            for (entity, anim) in allAnimations {
                let controller = entity.playAnimation(anim.repeat())
                controller.speed = 1.0
            }
        }
    }

    // MARK: - 走位插值

    /// 每帧朝 MovementService 的 targetPosition / targetYaw 插值；到达后通知服务唤醒等待方。
    /// 使用实际帧间时长（dt）做速率积分，避免帧率抖动导致速度不一致。
    private func updateMovement(anchor: Entity) {
        let now = Date().timeIntervalSince1970
        let dt: Float
        if moveClock.last == 0 {
            dt = 0
        } else {
            dt = min(Float(now - moveClock.last), 0.1)  // 卡一下、长帧时 clamp
        }
        moveClock.last = now
        guard dt > 0 else { return }

        let svc = appModel.movementService

        // ---- 转身 ----
        if let targetYaw = svc.targetYaw {
            let currentYaw = extractYRotation(from: anchor.transform.rotation)
            let delta = normalizeAngle(targetYaw - currentYaw)
            let step = svc.turnSpeed * dt
            if abs(delta) <= max(step, svc.arriveYaw) {
                anchor.transform.rotation = simd_quatf(angle: targetYaw, axis: SIMD3<Float>(0, 1, 0))
                svc.notifyYawArrived()
            } else {
                let newYaw = currentYaw + (delta > 0 ? step : -step)
                anchor.transform.rotation = simd_quatf(angle: newYaw, axis: SIMD3<Float>(0, 1, 0))
            }
        }

        // ---- 平移 ----
        if let targetPos = svc.targetPosition {
            let current = anchor.position
            let diff = SIMD3<Float>(targetPos.x - current.x, 0, targetPos.z - current.z)
            let dist = simd_length(diff)
            let step = svc.moveSpeed * dt
            if dist <= max(step, svc.arriveDistance) {
                anchor.position = SIMD3<Float>(targetPos.x, current.y, targetPos.z)
                svc.notifyPositionArrived()
            } else {
                let unit = diff / dist
                anchor.position = current + unit * step
            }
        }
    }

    // MARK: - 目光跟随

    private func updateGaze(anchor: Entity) {
        let headPos = appModel.trackingService.headPosition
        guard headPos != .zero else { return }

        let characterPos = anchor.position
        let direction = SIMD2<Float>(
            headPos.x - characterPos.x,
            headPos.z - characterPos.z
        )

        guard simd_length(direction) > 0.1 else { return }

        let targetAngle = atan2(direction.x, direction.y)
        let currentAngle = extractYRotation(from: anchor.transform.rotation)

        let smoothFactor: Float = 0.05
        let angleDiff = normalizeAngle(targetAngle - currentAngle)
        let newAngle = currentAngle + angleDiff * smoothFactor

        anchor.transform.rotation = simd_quatf(angle: newAngle, axis: SIMD3<Float>(0, 1, 0))
    }

    private func extractYRotation(from q: simd_quatf) -> Float {
        let siny = 2.0 * (q.real * q.imag.y + q.imag.x * q.imag.z)
        let cosy = 1.0 - 2.0 * (q.imag.x * q.imag.x + q.imag.y * q.imag.y)
        return atan2(siny, cosy)
    }

    private func normalizeAngle(_ angle: Float) -> Float {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    // MARK: - 手势响应

    private func handleGesture(_ gesture: HandGestureType) {
        guard let persona = appModel.currentPersona else { return }
        // print("👋 响应手势: \(gesture.rawValue)")

        // 走位优先：招手→过来，推手→退后
        switch gesture {
        case .wave:
            Task { await appModel.performWalk(.towardUser) }
            return
        case .push:
            Task { await appModel.performWalk(.backward) }
            return
        default:
            break
        }

        // 其余手势 → 查找匹配动画
        let targetID: String?
        switch gesture {
        case .thumbsUp:
            targetID = "shyBow"
        case .openPalm:
            targetID = "palmRight"
        default:
            targetID = nil
        }

        if let id = targetID,
           let mapping = persona.animation(forAPIName: id) {
            appModel.selectedAnimation = mapping.fileName
        }
    }

    // MARK: - 工具

    final class FrameTickCounter {
        private var n: Int = 0
        func tick(_ body: (Int) -> Void) { n += 1; body(n) }
    }

    /// 走位时间基准 box，用于在 RealityView.update 闭包里安全地写入而不触发
    /// "Modifying state during view update" 警告。
    final class MoveClock {
        var last: TimeInterval = 0
    }

    final class VisemeWeightStore {
        private var weights: [Viseme: Float] = [:]
        func weight(for v: Viseme) -> Float { weights[v] ?? 0 }
        func setWeight(_ w: Float, for v: Viseme) { weights[v] = w }
        func reset() { weights.removeAll() }
    }

    private static func findAllAnimations(in entity: Entity) -> [(Entity, AnimationResource)] {
        var results: [(Entity, AnimationResource)] = []
        for anim in entity.availableAnimations {
            results.append((entity, anim))
        }
        for child in entity.children {
            results.append(contentsOf: findAllAnimations(in: child))
        }
        return results
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
