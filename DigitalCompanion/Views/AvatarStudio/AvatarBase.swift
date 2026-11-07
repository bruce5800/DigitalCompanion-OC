//
//  AvatarBase.swift
//  DigitalCompanion
//
//  捏人底模(离散身体):女/男。
//  身高/体型不做骨骼缩放(会和烘焙动画打架),用离散底模承载 ——
//  每个底模一套完整资产(custom_{f|m}_{clip}.usdz × 12),
//  AvatarRecipe.baseID 存 rawValue。
//

import Foundation

enum AvatarBase: String, CaseIterable, Identifiable {
    case female = "f"
    case male = "m"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .female: return "女生"
        case .male:   return "男生"
        }
    }

    /// 该底模某个动画剪辑的 USDZ 资源名(不含扩展名)
    func fileName(clip: String) -> String { "custom_\(rawValue)_\(clip)" }

    /// 角色工坊预览用的底模资产
    var idleFileName: String { fileName(clip: "idle") }
}
