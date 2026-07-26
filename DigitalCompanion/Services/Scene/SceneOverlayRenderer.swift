//
//  SceneOverlayRenderer.swift
//  DigitalCompanion
//
//  Phase 2 调试可视化：把 SceneUnderstandingService 检测到的 plane 绘制成
//  半透明彩色矩形，叠加到 immersive space 里。
//
//  目的：让你亲眼看到 ARKit 把哪块当成了 floor / seat / table / wall / POI / other，
//  尤其是 `other=18` 这种情况——哪 18 块被漏分类了？它们是椅子？床？床头柜？
//
//  设计：
//  - 引用类型；持有一张 [UUID: ModelEntity] 字典做增量 diff
//  - sync(from:to:) 每帧被 ImmersiveView.update 调用（由 sceneService 的 @Observable
//    读取触发重跑）；新 plane 创建 entity，消失的销毁，已有的 transform 覆盖更新
//  - overlayRoot 挂在场景根上，独立于 characterAnchor（不会跟角色一起平移）
//  - 颜色编码：floor 绿 / seat 青 / table 黄 / wall 灰 / door 紫 / window 蓝 / other 橙
//

import Foundation
import RealityKit
import ARKit
import simd
import SwiftUI  // for Color -> SimpleMaterial base color

@MainActor
final class SceneOverlayRenderer {

    // MARK: - 调色盘（RGBA in 0..1）

    private static let colorFloor    = SIMD4<Float>(0.20, 0.95, 0.30, 0.25)  // 绿
    private static let colorSeat     = SIMD4<Float>(0.20, 0.85, 0.95, 0.45)  // 青（ARKit / 启发式）
    private static let colorSeatUser = SIMD4<Float>(1.00, 0.30, 0.65, 0.70)  // 粉（用户手动标记，更显眼）
    private static let colorTable    = SIMD4<Float>(0.95, 0.85, 0.15, 0.30)  // 黄
    private static let colorWall     = SIMD4<Float>(0.70, 0.70, 0.70, 0.15)  // 灰（墙多，透明度低）
    private static let colorWindow   = SIMD4<Float>(0.30, 0.55, 0.95, 0.45)  // 蓝
    private static let colorDoor     = SIMD4<Float>(0.75, 0.35, 0.95, 0.45)  // 紫
    private static let colorOther    = SIMD4<Float>(1.00, 0.55, 0.10, 0.55)  // 橙（显眼，诊断用）

    // MARK: - 状态

    /// 当前活着的 overlay entity，键 = anchor id（复用 plane anchor 的 UUID）
    private var entities: [UUID: ModelEntity] = [:]

    /// 上一次 sync 时"开关"是开还是关——从关到开要把所有已有 plane 画出来；
    /// 从开到关要把所有 entity 清掉
    private var wasEnabled: Bool = false

    // MARK: - 入口

    /// 每帧（或每次 sceneService 变化）被调用一次。
    /// 传入 overlayRoot：所有 overlay entity 都挂在它下面，便于整体开关 / 清理。
    func sync(from service: SceneUnderstandingService,
              enabled: Bool,
              to overlayRoot: Entity) {

        // 开关状态切换
        if !enabled {
            if wasEnabled { clearAll(overlayRoot: overlayRoot) }
            wasEnabled = false
            return
        }
        wasEnabled = true

        // 本轮应该存在的 id → (visual, color)
        var desired: [UUID: (PlaneVisual, SIMD4<Float>)] = [:]
        for f in service.floorRegions   { desired[f.id] = (f.visual, Self.colorFloor) }
        for s in service.seats {
            let color = (s.source == .userMarked) ? Self.colorSeatUser : Self.colorSeat
            desired[s.id] = (s.visual, color)
        }
        for t in service.tables         { desired[t.id] = (t.visual, Self.colorTable) }
        // obstacles 按 kind 分色：wall 灰（ARKit 原生墙）/ table 黄（重分类高水平面）
        // / other 橙（启发式分到的垂直家具面，重点观察 → 能看到椅背/床头板分布）
        for w in service.obstacles {
            let color: SIMD4<Float>
            switch w.kind {
            case .wall:  color = Self.colorWall
            case .table: color = Self.colorTable
            case .other: color = Self.colorOther
            }
            desired[w.id] = (w.visual, color)
        }
        for p in service.pointsOfInterest {
            let color = (p.kind == .window) ? Self.colorWindow : Self.colorDoor
            desired[p.id] = (p.visual, color)
        }
        for u in service.unclassifiedPlanes { desired[u.id] = (u.visual, Self.colorOther) }

        // 1) 淘汰不再存在的 entity
        for (id, ent) in entities where desired[id] == nil {
            ent.removeFromParent()
            entities.removeValue(forKey: id)
        }

        // 2) 创建/更新仍在的 entity
        for (id, pair) in desired {
            let (visual, color) = pair
            if let existing = entities[id] {
                updateEntity(existing, visual: visual, color: color)
            } else {
                let new = makeEntity(visual: visual, color: color)
                overlayRoot.addChild(new)
                entities[id] = new
            }
        }
    }

    /// 关闭 overlay 时调用：清掉所有已创建的 entity
    func clearAll(overlayRoot: Entity) {
        for (_, ent) in entities { ent.removeFromParent() }
        entities.removeAll()
    }

    // MARK: - Entity 生成

    private func makeEntity(visual: PlaneVisual, color: SIMD4<Float>) -> ModelEntity {
        // 矩形 mesh：extent 局部系是 XY 平面（法线 +Z），所以用 `width:height:` 版本
        // 生成的 mesh 正好嵌在 XY（法线 +Z），与 extent→world transform 匹配。
        // （之前用 `width:depth:` 版本生成 XZ 平面，会把矩形立起来 90°，
        //  表现是：floor 的绿色矩形竖着立在房间里。）
        let mesh = MeshResource.generatePlane(width: visual.width, height: visual.height)
        let material = makeMaterial(color: color)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.transform = Transform(matrix: visual.worldFromExtent)
        // overlay 不参与碰撞/命中测试
        entity.components.remove(CollisionComponent.self)
        return entity
    }

    private func updateEntity(_ entity: ModelEntity, visual: PlaneVisual, color: SIMD4<Float>) {
        // Plane 的长宽可能会被 ARKit 更新（它逐渐把 extent 扩大）；
        // 偷懒的做法是每次都新建 mesh。plane 更新频率不高，不心疼。
        let mesh = MeshResource.generatePlane(width: visual.width, height: visual.height)
        entity.model?.mesh = mesh
        entity.transform = Transform(matrix: visual.worldFromExtent)
        if let first = entity.model?.materials.first as? UnlitMaterial,
           first.color.tint != uiColor(color) {
            entity.model?.materials = [makeMaterial(color: color)]
        }
    }

    private func makeMaterial(color: SIMD4<Float>) -> UnlitMaterial {
        var mat = UnlitMaterial(color: uiColor(color))
        mat.blending = .transparent(opacity: .init(floatLiteral: color.w))
        return mat
    }

    private func uiColor(_ c: SIMD4<Float>) -> UIColor {
        UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w))
    }
}
