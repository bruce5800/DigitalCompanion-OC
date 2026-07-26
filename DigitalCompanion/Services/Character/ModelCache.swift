//
//  ModelCache.swift
//  DigitalCompanion
//
//  USDZ 模型的 LRU 缓存 + 动画挂载握手。
//  从 AppModel 拆出来的，纯粹的加载 / 缓存 / 挂载事件通知，不依赖业务状态。
//

import Foundation
import RealityKit
import RealityKitContent

/// 角色 USDZ 模型缓存。
///
/// 职责拆分：
/// - LRU 模板缓存：最多 3 个 `Entity`（Vision Pro 显存紧张），命中时 clone 返回
/// - "已挂载"握手：performWalk / performWalkToPoint 切 walk 动画后需要等 ImmersiveView
///   真把 USDZ 加到 anchor 上再开始平移，否则 0.5m 短走位会"滑过去没动画"
///
/// 不是 Service 层的对外能力，而是 AppModel 的内部私货；不加 print 以免 Observable
/// 重跑 UI —— @Observable 只追踪声明了 observable 的字段。
@MainActor
@Observable
final class ModelCache {

    /// 当前是否正在加载模型（ContentView 可以用来显示 loading 小菊花）
    var isLoadingModel = false

    /// ImmersiveView 最近一次完成挂载的 USDZ 文件名
    @ObservationIgnored private(set) var attachedAnimationFileName: String = ""

    /// 最大缓存数量（3 个约 450MB）
    @ObservationIgnored private let maxCacheSize = 3

    @ObservationIgnored private var modelCache: [String: Entity] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []

    /// 等待 attached 的回调队列（按目标 fileName 分组）
    @ObservationIgnored private var attachmentWaiters: [(fileName: String, continuation: CheckedContinuation<Void, Never>)] = []

    // MARK: - 加载

    /// 从缓存克隆 / 或从 bundle 异步加载一个 USDZ 模型。
    func loadModel(fileName: String) async -> Entity? {
        // 缓存命中：克隆并更新访问顺序
        if let template = modelCache[fileName] {
            updateCacheOrder(fileName)
            return template.clone(recursive: true)
        }

        // 缓存未命中：从磁盘加载
        isLoadingModel = true
        defer { isLoadingModel = false }

        // RealityKitContent(内置角色 usdz)→ 主 bundle 兜底。
        // 自定义角色是"共享几何 + 薄动画层"的 .usdc 集(贴图/几何跨剪辑共享,
        // 见 tools/vroid_pipeline/05_make_thin_set.py),所以要多探一个扩展名。
        // 兼容垫:多底模引入前保存的角色引用 "custom_idle" 这类无前缀旧名 →
        // 映射到女性底模(重新保存角色后自然消失)。
        func resolve(_ name: String) -> URL? {
            // 内置角色瘦身集按角色分文件夹(oc/sg/xo,Package .copy 整目录)
            let charFolder = String(name.prefix(while: { $0 != "_" }))
            for ext in ["usdz", "usdc"] {
                if let u = realityKitContentBundle.url(forResource: name, withExtension: ext) {
                    return u
                }
                if let u = realityKitContentBundle.url(forResource: name, withExtension: ext,
                                                       subdirectory: charFolder) {
                    return u
                }
                if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
                if let u = Bundle.main.url(forResource: name, withExtension: ext,
                                           subdirectory: "CustomAvatarAssets") { return u }
            }
            return nil
        }
        var legacyName: String? = nil
        if fileName.hasPrefix("custom_"),
           !fileName.hasPrefix("custom_f_"), !fileName.hasPrefix("custom_m_") {
            legacyName = "custom_f_" + fileName.dropFirst("custom_".count)
        }
        guard let url = resolve(fileName) ?? legacyName.flatMap(resolve) else {
            print("❌ 找不到 \(fileName).usdz/.usdc")
            return nil
        }

        do {
            let entity = try await Entity(contentsOf: url)
            entity.name = fileName

            // 淘汰最旧的缓存
            if modelCache.count >= maxCacheSize, let oldest = cacheOrder.first {
                modelCache.removeValue(forKey: oldest)
                cacheOrder.removeFirst()
            }

            modelCache[fileName] = entity
            cacheOrder.append(fileName)

            return entity.clone(recursive: true)
        } catch {
            print("❌ 模型加载失败: \(error)")
            return nil
        }
    }

    private func updateCacheOrder(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    /// 释放缓存（角色切换时调用）
    func clear() {
        modelCache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - 动画挂载握手

    /// ImmersiveView 在 loadAndAttach 成功后调用。
    /// 唤醒所有等待同名挂载的 continuation。
    func notifyAnimationAttached(_ fileName: String) {
        attachedAnimationFileName = fileName
        let matched = attachmentWaiters.filter { $0.fileName == fileName }
        attachmentWaiters.removeAll { $0.fileName == fileName }
        for item in matched { item.continuation.resume() }
    }

    /// 等待指定文件名挂载到场景。若已挂载则立即返回。
    /// 注意：只等"同名"的挂载信号，避免被后续切回 idle 的挂载误唤醒。
    func awaitAnimationAttached(_ fileName: String) async {
        if attachedAnimationFileName == fileName { return }
        await withCheckedContinuation { cont in
            attachmentWaiters.append((fileName, cont))
        }
    }
}
