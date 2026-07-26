//
//  SceneUnderstandingService.swift
//  DigitalCompanion
//
//  场景理解服务（Phase 1 骨架）
//  - 跑独立的 ARKitSession + PlaneDetectionProvider（水平+垂直）
//  - 按分类把 PlaneAnchor 拆成：floorRegions / seats / tables / obstacles / pointsOfInterest
//  - 所有几何都从 ARKit 本地坐标换算到世界坐标，XZ 投影后以 SIMD2<Float> 多边形存
//  - 后续 Phase：NavigationService 只从本服务读"稳定快照"，不自己管 anchor 生命周期
//
//  MVP 策略：
//  - 用 anchor.id (UUID) 作为字典主键，add/update/remove 事件全部走这一个通道
//  - 不做跨 anchor 的合并（比如两块拼起来的地板）；NavigationService 可以在后面处理
//  - isReady = 至少扫到 1 块 floor 且距离第一条事件已经过了 2s
//

import Foundation
import ARKit
import simd
import QuartzCore  // CACurrentMediaTime()

@MainActor
@Observable
class SceneUnderstandingService {

    // MARK: - 公开数据（SwiftUI / 调试面板 / NavigationService 都读这些）

    /// 可走区域：分类为 .floor 的水平面
    private(set) var floorRegions: [FloorRegion] = []

    /// 可坐点：分类为 .seat
    private(set) var seats: [Seat] = []

    /// 桌面：分类为 .table（Phase 1 里只当障碍；后续可作"放东西"用）
    private(set) var tables: [Obstacle] = []

    /// 障碍：.wall / .ceiling 暂不计 / 未分类但明显挡路的
    private(set) var obstacles: [Obstacle] = []

    /// 兴趣点：.window / .door —— Autonomous 模式里角色会"走过去看一眼"
    private(set) var pointsOfInterest: [PointOfInterest] = []

    /// 未分类 plane（.unknown / .notAvailable 等）。
    /// 诊断用：如果你知道房间里有椅子但 seats=0 而此列表非空，
    /// 说明 ARKit 看到了东西但没分类出来——Phase 2 可视化可以直接看到它们。
    private(set) var unclassifiedPlanes: [UnclassifiedPlane] = []

    /// 便捷计数
    var unclassifiedCount: Int { unclassifiedPlanes.count }

    /// 用户手动标记的座位（Phase 2.5）。
    /// 设备的 ARKit 对软质椅面/床面识别率低，靠启发式也补不回来——
    /// 所以提供一个"站在椅子前按一下"的兜底接口，让用户亲自标记。
    /// 这些 seat 会合并进 `seats`，但带一个 `.userMarked` source 标识，
    /// overlay 用更显眼的颜色（粉色圆盘 + 朝向箭头）区分。
    private(set) var userMarkedSeats: [Seat] = []

    /// 是否已就绪（至少有地板 + 超过初始稳定时间）
    private(set) var isReady: Bool = false

    /// 当前是否在跑 session
    private(set) var isRunning: Bool = false

    /// 最近一次错误（用于 UI 显示）
    private(set) var lastError: String?

    // MARK: - 调参

    /// 初始稳定时间：从第一条事件算起，过了这么久且有地板才认为 isReady
    let readyStabilizationDelay: TimeInterval = 2.0

    // MARK: - 私有状态

    private let arSession = ARKitSession()
    private let planeProvider = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
    /// 用于读头显当前位姿（markSeatInFrontOfUser 会查询一次）。
    /// 和 planeProvider 共用一个 ARKitSession，共用一次 .worldSensing 授权。
    private let worldTrackingProvider = WorldTrackingProvider()

    /// 用 anchor id 作为主键的镜像字典（方便 add/update/remove 增量维护）
    private var anchorTable: [UUID: PlaneAnchor] = [:]

    /// 第一次收到事件的时间（用于 isReady 判定）
    private var firstEventTime: Date?

    /// 主 loop 任务
    private var runLoopTask: Task<Void, Never>?

    // MARK: - 生命周期

    /// 由 AppModel 在 immersive space 打开后调用
    func start() async {
        guard !isRunning else { return }

        // 设备能力检查
        guard PlaneDetectionProvider.isSupported else {
            lastError = "当前设备不支持 PlaneDetectionProvider（模拟器常见）"
            print("⚠️ \(lastError ?? "")")
            return
        }

        // 授权
        let authResult = await arSession.requestAuthorization(for: [.worldSensing])
        guard authResult[.worldSensing] == .allowed else {
            lastError = "World Sensing 权限未授予"
            print("⚠️ \(lastError ?? "")")
            return
        }

        do {
            try await arSession.run([planeProvider, worldTrackingProvider])
            isRunning = true
            lastError = nil
            print("🗺️ SceneUnderstanding 启动")
        } catch {
            lastError = "ARKit 启动失败: \(error.localizedDescription)"
            print("❌ \(lastError ?? "")")
            return
        }

        runLoopTask = Task { [weak self] in
            await self?.consumeAnchorUpdates()
        }
    }

    func stop() {
        runLoopTask?.cancel()
        runLoopTask = nil
        arSession.stop()
        isRunning = false
        isReady = false
        anchorTable.removeAll()
        floorRegions.removeAll()
        seats.removeAll()
        tables.removeAll()
        obstacles.removeAll()
        pointsOfInterest.removeAll()
        unclassifiedPlanes.removeAll()
        userMarkedSeats.removeAll()
        firstEventTime = nil
        print("🗺️ SceneUnderstanding 已停止")
    }

    // MARK: - 手动标记座位（Phase 2.5）

    /// 用户按"📍 标记座位"按钮时调用：
    /// - 读取头显当前位姿
    /// - 在"头显前方 0.5m、脚下 floor 高度 + 0.45m"处生成一个 seat
    /// - yaw 取"人朝我"（反转设备前向）——这样角色坐下后会面向用户位置
    /// - 返回 true 表示成功，false 表示条件不满足（未 ready / 读不到位姿）
    @discardableResult
    func markSeatInFrontOfUser() -> Bool {
        guard isReady else {
            print("⚠️ markSeat: 场景未就绪")
            return false
        }
        guard let deviceAnchor = worldTrackingProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              deviceAnchor.isTracked else {
            print("⚠️ markSeat: 拿不到头显位姿")
            return false
        }
        guard let floorY = floorRegions.map({ $0.center.y }).min() else {
            print("⚠️ markSeat: 没有 floor 参考高度")
            return false
        }

        let t = deviceAnchor.originFromAnchorTransform
        let headPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // visionOS/RealityKit 约定：设备本地 -Z 是观察方向
        let fwd3 = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        // 只取水平分量
        var fwdXZ = SIMD2<Float>(fwd3.x, fwd3.z)
        let fwdLen = simd_length(fwdXZ)
        guard fwdLen > 1e-4 else {
            print("⚠️ markSeat: 头显朝向几乎竖直，无法推前方")
            return false
        }
        fwdXZ /= fwdLen

        let seatDistance: Float = 0.5        // 脚前 0.5m
        let seatHeightAboveFloor: Float = 0.45

        let seatXZ = SIMD2<Float>(headPos.x, headPos.z) + fwdXZ * seatDistance
        let seatCenter = SIMD3<Float>(seatXZ.x, floorY + seatHeightAboveFloor, seatXZ.y)

        // 面向用户 = 前向反转后的 atan2
        let faceUser = -fwdXZ
        let yaw = atan2(faceUser.x, faceUser.y)  // (x, z) → (fx, fz)；SIMD2 的 .y 是 z

        // 用户 seat 没有真实 plane；给个 0.4 × 0.4 的占位，朝世界 +Y，便于 overlay 放圆盘
        let size: Float = 0.4
        // worldFromExtent：仅平移到 seatCenter，朝向水平（法线 +Y 即世界 +Y）
        // 手动构造：extent 系是 XY 平面（法线 +Z），要让 +Z 对齐世界 +Y，绕 X 转 -90°
        let rx = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0)))
        var trans = matrix_identity_float4x4
        trans.columns.3 = SIMD4<Float>(seatCenter.x, seatCenter.y, seatCenter.z, 1)
        let worldFromExtent = trans * rx

        let halfS = size * 0.5
        let poly: [SIMD2<Float>] = [
            SIMD2<Float>(seatXZ.x - halfS, seatXZ.y - halfS),
            SIMD2<Float>(seatXZ.x + halfS, seatXZ.y - halfS),
            SIMD2<Float>(seatXZ.x + halfS, seatXZ.y + halfS),
            SIMD2<Float>(seatXZ.x - halfS, seatXZ.y + halfS),
        ]

        let visual = PlaneVisual(
            worldFromExtent: worldFromExtent,
            width: size,
            height: size,
            isHorizontal: true
        )

        let seat = Seat(
            id: UUID(),
            center: seatCenter,
            yaw: yaw,
            area: size * size,
            polygon: poly,
            visual: visual,
            source: .userMarked
        )
        userMarkedSeats.append(seat)
        rebuildPublicLists()
        print("📍 标记 seat #\(userMarkedSeats.count) 位置=\(seatCenter) yaw=\(String(format: "%.2f", yaw))")
        return true
    }

    /// 清掉所有手动标记的座位（不影响 ARKit 识别的）
    func clearUserMarkedSeats() {
        guard !userMarkedSeats.isEmpty else { return }
        userMarkedSeats.removeAll()
        rebuildPublicLists()
        print("📍 清空手动标记")
    }

    /// A2 情境感知：给 LLM 一段简短的环境描述。
    /// 没启动 / 没扫到东西 → nil（PromptBuilder 不会注入空段落）
    func summarize() -> String? {
        guard isRunning else { return nil }
        guard isReady else {
            return "房间扫描中，还没看清环境。"
        }

        var parts: [String] = []
        let seatCount = seats.count + userMarkedSeats.count
        if seatCount > 0 { parts.append("\(seatCount) 把椅子") }
        if !tables.isEmpty { parts.append("\(tables.count) 张桌子") }

        let windowCount = pointsOfInterest.filter { $0.kind == .window }.count
        let doorCount = pointsOfInterest.filter { $0.kind == .door }.count
        if windowCount > 0 { parts.append("\(windowCount) 扇窗户") }
        if doorCount > 0 { parts.append("\(doorCount) 扇门") }

        if parts.isEmpty {
            return "房间扫描完成，但暂无可识别的家具。"
        }
        return "房间里有 " + parts.joined(separator: "、")
    }

    // MARK: - 主 loop

    private func consumeAnchorUpdates() async {
        for await update in planeProvider.anchorUpdates {
            if firstEventTime == nil { firstEventTime = Date() }

            switch update.event {
            case .added, .updated:
                anchorTable[update.anchor.id] = update.anchor
            case .removed:
                anchorTable.removeValue(forKey: update.anchor.id)
            }

            rebuildPublicLists()
            updateReadyState()
        }
    }

    /// 基于 anchorTable 重新算公开数组。
    /// Plane 更新频率不高（每秒几次），全量重算不心疼；后续如果成为热点再改增量。
    private func rebuildPublicLists() {
        var floors: [FloorRegion] = []
        var seatList: [Seat] = []
        var tableList: [Obstacle] = []
        var obstacleList: [Obstacle] = []
        var poiList: [PointOfInterest] = []
        var otherList: [UnclassifiedPlane] = []

        // 未分类 plane 先缓存，等第一轮拿到 floors 后按离地高度再处理
        // —— ARKit 常把椅子/床/柜子/暖气/垃圾桶标为 .unknown，
        //    启发式重分类能让它们进入 seat / obstacle 正确参与行为。
        typealias PendingUnknown = (anchor: PlaneAnchor, projected: ProjectedPlane, visual: PlaneVisual)
        var pending: [PendingUnknown] = []

        for (_, anchor) in anchorTable {
            guard let projected = projectToWorld(anchor) else { continue }
            let visual = PlaneVisual(
                worldFromExtent: projected.worldFromExtent,
                width: projected.width,
                height: projected.height,
                isHorizontal: projected.alignment == .horizontal
            )

            switch anchor.surfaceClassification {
            case .floor:
                floors.append(FloorRegion(
                    id: anchor.id,
                    center: projected.center,
                    polygon: projected.polygon,
                    area: projected.area,
                    visual: visual
                ))
            case .seat:
                seatList.append(Seat(
                    id: anchor.id,
                    center: projected.center,
                    yaw: yawFromNormal(anchor: anchor),
                    area: projected.area,
                    polygon: projected.polygon,
                    visual: visual,
                    source: .arkit
                ))
            case .table:
                tableList.append(Obstacle(
                    id: anchor.id,
                    kind: .table,
                    center: projected.center,
                    polygon: projected.polygon,
                    visual: visual
                ))
            case .wall:
                obstacleList.append(Obstacle(
                    id: anchor.id,
                    kind: .wall,
                    center: projected.center,
                    polygon: projected.polygon,
                    visual: visual
                ))
            case .window:
                poiList.append(PointOfInterest(
                    id: anchor.id,
                    kind: .window,
                    position: projected.center,
                    normal: worldNormal(of: anchor),
                    visual: visual
                ))
            case .door:
                poiList.append(PointOfInterest(
                    id: anchor.id,
                    kind: .door,
                    position: projected.center,
                    normal: worldNormal(of: anchor),
                    visual: visual
                ))
            case .ceiling:
                continue  // 不关心
            default:
                pending.append((anchor, projected, visual))
                continue
            }
        }

        // —— 重分类：需要 floor 参考高度 ——
        // ARKit 的世界原点 Y 不固定（取决于 session 启动时头显位置），
        // 所以"离地高度"只能用 floors 的最低 y 作基准；没有 floor 就全部暂且当 other。
        let floorY: Float? = floors.map { $0.center.y }.min()

        for p in pending {
            let cy = p.projected.center.y
            let relY: Float = (floorY != nil) ? (cy - floorY!) : .nan

            if p.projected.alignment == .horizontal, let _ = floorY {
                // 水平面：按离地高度分段
                // - 椅面/床面：0.25 ~ 0.80 m，面积 ≥ 0.10 m² → seat（供坐下）
                // - 柜顶/桌面：> 0.80 m → 当 table 类障碍（挡路但不能坐）
                // - 其余（太低/面积太小，如垃圾桶顶） → 继续当 other
                if relY >= 0.25, relY <= 0.80, p.projected.area >= 0.10 {
                    seatList.append(Seat(
                        id: p.anchor.id,
                        center: p.projected.center,
                        yaw: yawFromNormal(anchor: p.anchor),
                        area: p.projected.area,
                        polygon: p.projected.polygon,
                        visual: p.visual,
                        source: .heuristic
                    ))
                } else if relY > 0.80 {
                    obstacleList.append(Obstacle(
                        id: p.anchor.id,
                        kind: .table,
                        center: p.projected.center,
                        polygon: p.projected.polygon,
                        visual: p.visual
                    ))
                } else {
                    otherList.append(UnclassifiedPlane(
                        id: p.anchor.id,
                        center: p.projected.center,
                        visual: p.visual
                    ))
                }
            } else if p.projected.alignment == .vertical {
                // 垂直面：家具正面 / 暖气正面 / 未识别的门窗 → 一律当 other 类障碍，
                // 好让 Phase 3 的路径规划把它们算进来（避免角色撞家具）。
                obstacleList.append(Obstacle(
                    id: p.anchor.id,
                    kind: .other,
                    center: p.projected.center,
                    polygon: p.projected.polygon,
                    visual: p.visual
                ))
            } else {
                // 还没有 floor 基准，无法判断高度，先留着等下一轮
                otherList.append(UnclassifiedPlane(
                    id: p.anchor.id,
                    center: p.projected.center,
                    visual: p.visual
                ))
            }
        }

        // 合并手动标记的 seat（它们不是 plane，单独维护；但对外 `seats` 看起来一致）
        seatList.append(contentsOf: userMarkedSeats)

        self.floorRegions = floors
        self.seats = seatList
        self.tables = tableList
        self.obstacles = obstacleList
        self.pointsOfInterest = poiList
        self.unclassifiedPlanes = otherList
    }

    private func updateReadyState() {
        guard let first = firstEventTime else { return }
        let elapsed = Date().timeIntervalSince(first)
        let shouldBeReady = !floorRegions.isEmpty && elapsed >= readyStabilizationDelay
        if shouldBeReady != isReady {
            isReady = shouldBeReady
            if shouldBeReady {
                print("🗺️ SceneUnderstanding READY：floors=\(floorRegions.count) seats=\(seats.count) tables=\(tables.count) walls=\(obstacles.count) POI=\(pointsOfInterest.count) other=\(unclassifiedCount)")
            }
        }
    }

    // MARK: - 几何换算

    /// 把 plane anchor 的几何投影到世界坐标（XZ 平面）。
    /// 用 `geometry.extent` 拿到 plane 的矩形边界（w × h + 局部变换），
    /// 再把 4 个角点依次过 `anchorFromExtent → originFromAnchor` 得到世界系矩形。
    /// 水平面的矩形直接就是可走/可坐 footprint；垂直面（墙/门/窗）取 4 角 XZ 投影作为障碍 footprint。
    private func projectToWorld(_ anchor: PlaneAnchor) -> ProjectedPlane? {
        let extent = anchor.geometry.extent
        let w = extent.width
        let h = extent.height
        guard w > 0.001 && h > 0.001 else { return nil }

        // 在 extent 局部系里，平面位于 XY（法线 = +Z），中心在原点，边长 w × h
        // （visionOS 的 PlaneAnchor.Geometry.Extent 约定是 XY 平面，
        //  如果用 XZ 坐标取角点会导致可视化 mesh 立起来 90°。）
        let halfW = w * 0.5
        let halfH = h * 0.5
        let localCorners: [SIMD3<Float>] = [
            SIMD3<Float>(-halfW, -halfH, 0),
            SIMD3<Float>( halfW, -halfH, 0),
            SIMD3<Float>( halfW,  halfH, 0),
            SIMD3<Float>(-halfW,  halfH, 0),
        ]

        let worldFromExtent = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform

        var worldVerts: [SIMD3<Float>] = []
        worldVerts.reserveCapacity(4)
        for c in localCorners {
            let h4 = SIMD4<Float>(c.x, c.y, c.z, 1)
            let wh = worldFromExtent * h4
            worldVerts.append(SIMD3<Float>(wh.x, wh.y, wh.z))
        }

        // XZ 投影多边形
        let polygon = worldVerts.map { SIMD2<Float>($0.x, $0.z) }

        // 中心
        var sum = SIMD3<Float>.zero
        for v in worldVerts { sum += v }
        let center = sum / Float(worldVerts.count)

        // 面积（shoelace on XZ）
        let area = polygonArea(polygon)

        return ProjectedPlane(
            polygon: polygon,
            center: center,
            area: area,
            worldFromExtent: worldFromExtent,
            width: w,
            height: h,
            alignment: anchor.alignment
        )
    }

    /// 从 anchor 的 transform 里取法向量（anchor 的 +Y 方向 → 转到世界系）
    private func worldNormal(of anchor: PlaneAnchor) -> SIMD3<Float> {
        let t = anchor.originFromAnchorTransform
        // plane local 的上方向 (0,1,0) 转世界
        let n = SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)
        return simd_normalize(n)
    }

    /// 座位朝向：对水平面来说 extent 的 +Y 是矩形"长边/短边"之一方向（水平），
    /// 取它在 XZ 的投影作为"座位前后轴"的合理代理；无法区分正反，
    /// Phase 5 可再用墙体邻近或用户位置修正。
    /// （extent 本地系是 XY 平面、+Z 法线 —— 所以水平面 extent +Z 就是世界 +Y，
    ///  投 XZ 后是零向量，取 +Y 列才有意义。）
    private func yawFromNormal(anchor: PlaneAnchor) -> Float {
        let t = anchor.originFromAnchorTransform * anchor.geometry.extent.anchorFromExtentTransform
        let forward = SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)
        let fx = forward.x
        let fz = forward.z
        guard fx*fx + fz*fz > 1e-6 else { return 0 }
        return atan2(fx, fz)
    }

    /// 多边形面积（Shoelace），输入无序/不闭合都能工作（自动闭合）
    private func polygonArea(_ poly: [SIMD2<Float>]) -> Float {
        guard poly.count >= 3 else { return 0 }
        var s: Float = 0
        for i in 0..<poly.count {
            let a = poly[i]
            let b = poly[(i + 1) % poly.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) * 0.5
    }

    // MARK: - 私有辅助类型

    private struct ProjectedPlane {
        let polygon: [SIMD2<Float>]
        let center: SIMD3<Float>
        let area: Float
        /// 世界 ← extent 矩形局部系 的变换；可视化时直接丢给 ModelEntity.transform
        let worldFromExtent: simd_float4x4
        let width: Float
        let height: Float
        let alignment: PlaneAnchor.Alignment
    }
}

// MARK: - 公开数据模型

/// 每个 plane 都带的"可视化元数据"（世界变换 + 尺寸 + 水平/垂直）
/// Overlay 渲染器直接读这四个字段画一个矩形；Navigation 层不 care 这些。
struct PlaneVisual: Sendable {
    let worldFromExtent: simd_float4x4
    let width: Float
    let height: Float
    let isHorizontal: Bool  // false 即 vertical（墙/门/窗）
}

/// 一块地板（可走区域）
struct FloorRegion: Identifiable, Sendable {
    let id: UUID
    let center: SIMD3<Float>
    let polygon: [SIMD2<Float>]  // 世界系 XZ
    let area: Float
    let visual: PlaneVisual
}

/// 一个座位
struct Seat: Identifiable, Sendable {
    /// 座位数据的来源：ARKit 原生分类 / 我们启发式重分类 / 用户手动标记
    enum Source: Sendable {
        case arkit       // anchor.surfaceClassification == .seat
        case heuristic   // 水平面 + 离地高度合理 → 重分类
        case userMarked  // 用户按按钮标记
    }
    let id: UUID
    let center: SIMD3<Float>
    /// 座位朝向（弧度，绕 Y）——坐下时角色应朝这个方向
    let yaw: Float
    let area: Float
    let polygon: [SIMD2<Float>]
    /// 用户标记的 seat 没有真实 plane，`visual` 是我们合成出来的小圆盘占位
    let visual: PlaneVisual
    let source: Source
}

/// 障碍（墙 / 桌 / 将来可能的杂物）
struct Obstacle: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case wall, table, other
    }
    let id: UUID
    let kind: Kind
    let center: SIMD3<Float>
    let polygon: [SIMD2<Float>]  // 世界系 XZ 投影包围
    let visual: PlaneVisual
}

/// 兴趣点（门/窗）——Autonomous 模式用
struct PointOfInterest: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case window, door
    }
    let id: UUID
    let kind: Kind
    let position: SIMD3<Float>
    /// 墙的外法向量；角色"面向窗"时要朝这个方向
    let normal: SIMD3<Float>
    let visual: PlaneVisual
}

/// 未分类平面（.unknown / .notAvailable）——Phase 2 可视化调试用
struct UnclassifiedPlane: Identifiable, Sendable {
    let id: UUID
    let center: SIMD3<Float>
    let visual: PlaneVisual
}
