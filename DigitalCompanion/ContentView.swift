//
//  ContentView.swift
//  DigitalCompanion
//
//  Created by 李卓伦 on 2026/3/28.
//

import SwiftUI
import RealityKit
import RealityKitContent
import CompanionCore

struct ContentView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    @State private var showUserPersonaEdit = false
    @State private var showGestureGuide = false
    @State private var didOpenScreenshotRoute = false
    /// 首次进入沉浸空间是否已弹过手势引导（持久化；以后加手势可升 v 号重弹）
    @AppStorage("hasSeenGestureGuide_v1") private var hasSeenGestureGuide = false

    var body: some View {
        @Bindable var appModel = appModel

        VStack(spacing: 0) {
            // 顶部：角色选择 + 标题 + 设置
            HStack {
                // 角色切换菜单
                Menu {
                    ForEach(appModel.availablePersonaIDs, id: \.self) { pid in
                        Button {
                            appModel.switchCharacter(to: pid)
                        } label: {
                            let isCurrent = appModel.currentPersona?.id == pid
                            Label(
                                CharacterPersona.load(named: pid)?.name ?? pid,
                                systemImage: isCurrent ? "checkmark.circle.fill" : "person.circle"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .font(.caption)
                        Text(appModel.currentPersona?.name ?? "数字伙伴")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                }
                .menuStyle(.borderlessButton)

                Spacer()

                // LLM 服务商指示
                Text(appModel.selectedProvider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 用户 Persona 编辑入口
                Button {
                    showUserPersonaEdit = true
                } label: {
                    Image(systemName: "person.crop.circle")
                }

                // 手势引导入口（随时可查）
                Button {
                    showGestureGuide = true
                } label: {
                    Image(systemName: "hand.point.up.left")
                }

                // 捏人间入口（实验中：自定义角色外观）
                Button {
                    openWindow(id: "avatarStudio")
                } label: {
                    Image(systemName: "paintbrush.pointed")
                }

                Button {
                    appModel.showAPIKeySetup = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // 模型加载指示器
            if appModel.isLoadingModel {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("切换动画中...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            // 聊天区域
            ChatView()

            // 场景扫描调试行（仅 immersive 开启时显示）
            if appModel.immersiveSpaceState == .open && shouldShowSceneDebugBar {
                SceneDebugBar()
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            // 底部状态栏
            HStack(spacing: 12) {
                if appModel.immersiveSpaceState == .open {
                    Text("动画: \(appModel.selectedAnimationDisplayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Phase 4：角色站位模式（静止 / 跟随 / 自主）
                // 只在 immersive 打开时可用——关闭时切换没意义，follow 依赖头部追踪
                if appModel.immersiveSpaceState == .open {
                    HStack(spacing: 6) {
                        Text("站位")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("站位", selection: $appModel.movementMode) {
                            ForEach(MovementMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                    }
                }

                // TTS 开关
                Button {
                    if appModel.ttsService.isSpeaking {
                        appModel.ttsService.stop()
                    } else {
                        appModel.isTTSEnabled.toggle()
                    }
                } label: {
                    Image(systemName: appModel.ttsService.isSpeaking
                          ? "speaker.wave.2.fill"
                          : appModel.isTTSEnabled ? "speaker.fill" : "speaker.slash.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Button("清空对话") {
                    // A0.2 起：清空当前角色的磁盘记录 + 重新发开场白
                    appModel.resetCurrentChat()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomOrnament) {
                ToggleImmersiveSpaceButton()
            }
        }
        .sheet(isPresented: $appModel.showAPIKeySetup) {
            APIKeySetupView()
                .environment(appModel)
        }
        .sheet(isPresented: $showUserPersonaEdit) {
            UserPersonaEditView()
                .environment(appModel)
        }
        .sheet(isPresented: $showGestureGuide) {
            GestureGuideView()
        }
        .onChange(of: appModel.immersiveSpaceState) { _, state in
            // 首次进入沉浸空间（手势此时才可用）→ 自动弹一次手势引导。
            // 避开和 API Key 设置 sheet 同时present（SwiftUI 同时只能弹一个，
            // 否则手势引导会被静默丢掉、而且 flag 已置位再也不弹）。配 key 的 sheet
            // 还在时先不弹，等下次进沉浸空间再弹。
            if state == .open && !hasSeenGestureGuide && !appModel.showAPIKeySetup {
                hasSeenGestureGuide = true
                showGestureGuide = true
            }
        }
        .onAppear {
            // 首次启动时如果没有 API Key，自动弹出设置
            if !appModel.isAPIKeyConfigured {
                appModel.showAPIKeySetup = true
            }
        }
        #if DEBUG
        .task {
            guard ScreenshotDemoData.isEnabled, !didOpenScreenshotRoute else { return }
            didOpenScreenshotRoute = true
            switch ScreenshotDemoData.route {
            case "immersive":
                hasSeenGestureGuide = true
                showGestureGuide = false
                try? await Task.sleep(for: .seconds(1))
                appModel.immersiveSpaceState = .inTransition
                if case .error = await openImmersiveSpace(id: appModel.immersiveSpaceID) {
                    appModel.immersiveSpaceState = .closed
                }
            case "avatar-studio":
                try? await Task.sleep(for: .seconds(1))
                openWindow(id: "avatarStudio")
            default:
                break
            }
        }
        #endif
    }

    private var shouldShowSceneDebugBar: Bool {
        #if DEBUG
        return !ScreenshotDemoData.isEnabled
        #else
        return true
        #endif
    }
}

/// Phase 1+2 用的场景扫描调试条：显示扫描状态 + 各类 anchor 计数 + 可视化开关。
/// 生产阶段可以拿掉或塞到更隐蔽的位置。
private struct SceneDebugBar: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        let svc = appModel.sceneService
        HStack(spacing: 10) {
            // 左：环境识别状态（自适应、可截断，绝不挤占右侧控件）
            HStack(spacing: 6) {
                Image(systemName: svc.isReady ? "viewfinder.circle.fill" : "viewfinder.circle")
                Text(scanStatusText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption2)
            .foregroundStyle(scanStatusColor)
            .layoutPriority(0)

            Spacer(minLength: 8)

            // 右：场景控件成组——紧凑、固定，不被左侧状态文字推散
            HStack(spacing: 12) {
                // 手动标记座位：站在椅子/床前按一下 → 脚前 0.5m 生成一个粉色 seat
                Button {
                    appModel.sceneService.markSeatInFrontOfUser()
                } label: {
                    Label("标记座位", systemImage: "mappin.and.ellipse")
                }
                .disabled(!svc.isReady)

                // Phase 5：走到最近一个手动标记的 seat 并坐下
                Button {
                    Task { await goToNearestUserSeat() }
                } label: {
                    Label("去坐下", systemImage: "figure.seated.side")
                }
                .disabled(svc.userMarkedSeats.isEmpty || !svc.isReady)

                // 清空手动标记（不影响 ARKit 识别的 seat）
                Button {
                    appModel.sceneService.clearUserMarkedSeats()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(svc.userMarkedSeats.isEmpty)

                Divider().frame(height: 16)

                // 可视化：把识别到的平面画成彩色矩形（紧挨着，和"环境识别"状态相呼应）
                Toggle(isOn: $appModel.isSceneVisualizationEnabled) {
                    Label("可视化", systemImage: "square.stack.3d.up.fill")
                }
                .toggleStyle(.button)
                .disabled(!svc.isRunning)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .buttonStyle(.borderless)
            .layoutPriority(1)
        }
        .padding(.vertical, 2)
    }

    /// 环境识别状态文案（导航失败 / 错误优先提示）
    private var scanStatusText: String {
        if let note = appModel.lastNavigationNote { return "🚧 \(note)" }
        if let err = appModel.sceneService.lastError { return "⚠️ \(err)" }
        if !appModel.sceneService.isRunning { return "环境扫描未启动" }
        if !appModel.sceneService.isReady { return "正在识别房间…走动一下" }
        return "环境已识别"
    }

    private var scanStatusColor: Color {
        if appModel.lastNavigationNote != nil || appModel.sceneService.lastError != nil { return .red }
        if appModel.sceneService.isReady { return .green }
        if appModel.sceneService.isRunning { return .orange }
        return .secondary
    }

    /// "去"按钮：挑一个离角色 XZ 距离最近的手动标记 seat，走过去并坐下
    /// （Phase 5：复用 AppModel.performSit —— 到位后自动切 sitIdle 动画）
    private func goToNearestUserSeat() async {
        let seats = appModel.sceneService.userMarkedSeats
        guard !seats.isEmpty else { return }
        let anchorPos = appModel.movementService.currentAnchorPosition
        let nearest = seats.min(by: { lhs, rhs in
            let dl = distSqXZ(lhs.center, anchorPos)
            let dr = distSqXZ(rhs.center, anchorPos)
            return dl < dr
        })!
        await appModel.performSit(at: nearest)
    }

    private func distSqXZ(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let dx = a.x - b.x
        let dz = a.z - b.z
        return dx * dx + dz * dz
    }
}

#Preview(windowStyle: .volumetric) {
    ContentView()
        .environment(AppModel())
}
