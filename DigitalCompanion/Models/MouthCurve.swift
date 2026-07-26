//
//  MouthCurve.swift
//  DigitalCompanion
//
//  表演(唱歌)用的口型包络曲线。
//
//  由 tools/song_pipeline/make_mouth_curve.py 从人声干声离线分析生成,
//  以 sidecar 形式随歌曲音频进 bundle:<音频名>_mouth.json。
//  运行时按 AVAudioPlayer.currentTime 采样,天然与音频对齐(不怕加载延迟)。
//

import Foundation

struct MouthCurve: Codable {
    /// 采样帧率(脚本默认 30)
    let fps: Double
    /// 每帧嘴巴张开度 0-1(已在脚本里做过 dB 映射 + 平滑)
    let values: [Float]

    /// 按播放进度采样;越界(未开始/已结束)返回 0 = 闭嘴
    func openness(at time: TimeInterval) -> Float {
        guard fps > 0, !values.isEmpty, time >= 0 else { return 0 }
        let idx = Int(time * fps)
        guard idx < values.count else { return 0 }
        return values[idx]
    }

    /// 定位并解码音频同名 sidecar 曲线(Audio/ 子目录或 bundle 根,
    /// 与 PerformanceService.locateAudio 同一套查找规则)
    static func locate(forAudioBaseName baseName: String) -> MouthCurve? {
        let name = baseName + "_mouth"
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Audio")
                ?? bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MouthCurve.self, from: data)
    }
}
