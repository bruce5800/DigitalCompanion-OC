//
//  NavigationService.swift
//  DigitalCompanion
//
//  Phase 3：直线可达性检查（straight-line reachability）。
//
//  职责很窄：给定起点 A、终点 B 和当前 SceneUnderstandingService 快照，
//  回答"角色能直线走过去吗？"—— 不做 A*，不做路径分段，不做绕行。
//  上层（AppModel.performWalkToPoint）用这个结果决定是否启动一次平移。
//
//  可达性定义（全部在 XZ 水平面上做）：
//    1. 终点 B 必须落在某一块 floor 的多边形内 —— 否则角色去了也是踩空地
//    2. 线段 A→B 不得进入任何 obstacle 多边形的"膨胀区"
//       —— 膨胀半径 inflateRadius（默认 0.3m）代表角色身体占用 + 安全余量
//
//  几何用法：
//    - floor / obstacle 的 polygon 都是 XZ 平面的 4 顶点矩形（SceneUnderstandingService
//      从 PlaneAnchor.extent 投出来的），不一定轴对齐（墙可能是 45° 角的）
//    - 点在多边形内：射线法（奇偶计数）
//    - 线段到多边形最近距离：对 4 条边做 segment-segment 最短距离，取最小
//
//  非目标（留给后续 Phase）：
//    - A*、多房间连通、跨阶梯高度
//    - 动态避障、路径平滑
//    - 沿对角墙的紧贴行走
//

import Foundation
import simd

@MainActor
struct NavigationService {

    /// 检查结果
    enum Reachability {
        case ok
        /// 终点不在任何 floor 里
        case targetOffFloor
        /// 线段被某个障碍挡住（附带障碍类型信息，调试用）
        case blocked(obstacleKind: String)
    }

    /// 角色身体占用半径（米）—— 线段到障碍的最短距离小于这个值就算挡住。
    /// 0.15 是降低后的默认值：原来 0.3 在小房间里太严格，很容易把"角色贴墙站立"误判成无路可走。
    /// 如果现实中角色撞墙了再往上调；一般不走绕行的情况下，这个值偏小更好。
    static let defaultInflateRadius: Float = 0.15

    /// 起点周围的"免检"距离（米）。
    /// 角色初始化时可能被放在离墙很近的位置、甚至被误判为落在某个家具 polygon 里；
    /// 这种情况下"从起点向外走"的所有路径都会被卡死。
    /// 免检段让我们只关心"离开起点之后会不会撞上东西"，而不关心起点本身是否已经贴着东西。
    static let startGuardDistance: Float = 0.2

    /// 主入口：A 是否能直线走到 B？
    /// - from: 角色当前 XZ 位置（Y 被忽略）
    /// - to: 目标 XZ 位置
    /// - scene: 拿 floorRegions / obstacles / tables 的快照
    /// - inflateRadius: 角色身体半径 + 安全余量
    static func checkReachability(
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        scene: SceneUnderstandingService,
        inflateRadius: Float = defaultInflateRadius
    ) -> Reachability {
        let a = SIMD2<Float>(from.x, from.z)
        let b = SIMD2<Float>(to.x, to.z)

        // 1) 终点必须落在某块 floor 里
        let targetOnFloor = scene.floorRegions.contains { pointInPolygon(b, polygon: $0.polygon) }
        if !targetOnFloor {
            return .targetOffFloor
        }

        // 2) 线段不得进入任何障碍的膨胀区
        // obstacles 已经包含 wall / table / other kind，都要避开。
        // tables（原生分类）也要避开 —— 它们不是 obstacles 数组里的，但本质是挡路的。
        // seats 不避 —— 角色就是要走到 seat。
        // POI（门/窗）不避 —— 门是路径的一部分，窗在墙上已经被 wall 覆盖了。
        for ob in scene.obstacles {
            if segmentNearPolygon(a, b, polygon: ob.polygon, radius: inflateRadius) {
                return .blocked(obstacleKind: "obstacle.\(ob.kind.rawValue)")
            }
        }
        for t in scene.tables {
            if segmentNearPolygon(a, b, polygon: t.polygon, radius: inflateRadius) {
                return .blocked(obstacleKind: "table")
            }
        }

        return .ok
    }

    // MARK: - 几何工具

    /// 射线法判点是否在多边形内（XZ 平面）
    /// 多边形可以不闭合；顶点顺序任意（CW/CCW 都行）
    private static func pointInPolygon(_ p: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            // 边 (pi, pj) 是否被从 p 出发的水平射线穿过
            if ((pi.y > p.y) != (pj.y > p.y)) {
                let slope = (pj.x - pi.x) / (pj.y - pi.y)
                let xIntersect = pi.x + (p.y - pi.y) * slope
                if p.x < xIntersect { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// 线段 (a,b) 是否在多边形"膨胀 radius"的区域内？
    ///
    /// 策略：沿线段按 t ∈ [startGuard, 1] 采样一串点，查每个点到多边形的最短距离；
    /// 只要有一个 < radius 就算挡住。
    ///
    /// 为什么跳过起点附近：
    ///   - 角色初始化 / 上一轮走位落点可能已经离墙很近（小房间里常态）
    ///   - 如果起点本身就在 inflate 区内，任何方向的走位都会被判死
    ///   - 免检段让"起步阶段"一律通过，只保证"走到目标附近和半路上"不撞东西
    private static func segmentNearPolygon(
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        polygon: [SIMD2<Float>],
        radius: Float
    ) -> Bool {
        guard polygon.count >= 2 else { return false }

        // 终点在多边形里 → 肯定挡（不会让角色走进家具里）
        if pointInPolygon(b, polygon: polygon) { return true }

        let segLen = simd_length(b - a)
        guard segLen > 1e-5 else { return false }

        // 起点免检比例：startGuardDistance 米 或 线段长度一半，取小
        let startT: Float = min(0.5, startGuardDistance / segLen)

        // 采样步数：线段越长步越多，但有上下限
        let stepLen: Float = 0.1  // 每 10cm 一个采样点
        let steps = max(4, min(24, Int(ceil(segLen / stepLen))))

        let r2 = radius * radius
        for i in 0...steps {
            let t = startT + (1 - startT) * Float(i) / Float(steps)
            let p = a + (b - a) * t
            if distanceSquaredToPolygon(p, polygon: polygon) < r2 {
                return true
            }
        }
        return false
    }

    /// 点到多边形的最短距离平方。
    /// 点在多边形内 → 返回 0（视为"距离 0，直接挡"）；否则取到各边最短距离。
    private static func distanceSquaredToPolygon(
        _ p: SIMD2<Float>,
        polygon: [SIMD2<Float>]
    ) -> Float {
        if pointInPolygon(p, polygon: polygon) { return 0 }
        var minD: Float = .infinity
        for i in 0..<polygon.count {
            let e0 = polygon[i]
            let e1 = polygon[(i + 1) % polygon.count]
            let d = pointSegmentDistanceSquared(p, e0, e1)
            if d < minD { minD = d }
        }
        return minD
    }

    /// 点到线段的距离平方
    private static func pointSegmentDistanceSquared(
        _ p: SIMD2<Float>,
        _ s0: SIMD2<Float>,
        _ s1: SIMD2<Float>
    ) -> Float {
        let d = s1 - s0
        let lenSq = simd_length_squared(d)
        if lenSq < 1e-12 {
            return simd_length_squared(p - s0)
        }
        let t = max(0, min(1, simd_dot(p - s0, d) / lenSq))
        let proj = s0 + d * t
        return simd_length_squared(p - proj)
    }

    /// 保留这两个辅助函数以备后续真·路径规划（A* / 可见性图）时用；
    /// 当前采样法的阻挡检查不直接依赖它们。
    private static func segmentsIntersect(
        _ a0: SIMD2<Float>, _ a1: SIMD2<Float>,
        _ b0: SIMD2<Float>, _ b1: SIMD2<Float>
    ) -> Bool {
        let d1 = cross2(b1 - b0, a0 - b0)
        let d2 = cross2(b1 - b0, a1 - b0)
        let d3 = cross2(a1 - a0, b0 - a0)
        let d4 = cross2(a1 - a0, b1 - a0)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    private static func cross2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        a.x * b.y - a.y * b.x
    }
}
