//
//  SceneSensitivity.swift
//  音频频谱的敏感度（0.5–2.0，默认 1.0）。独立 UserDefaults 键，实时生效。
//  实现上是归一化后的指数：敏感度高 → 指数 < 1 → 安静频段也被抬高，画面更"跳"。
//

import Foundation

enum SceneSensitivity {
    static let defaultsKey = "SceneSensitivity"
    static let minimum = 0.5
    static let maximum = 2.0

    static var value: Double {
        get {
            guard let v = UserDefaults.standard.object(forKey: defaultsKey) as? Double else { return 1.0 }
            return min(maximum, max(minimum, v))
        }
        set { UserDefaults.standard.set(min(maximum, max(minimum, newValue)), forKey: defaultsKey) }
    }

    /// 归一化后使用的指数：敏感度 2.0 → 0.5（抬得更多），0.5 → 2.0（压得更狠）。
    static var exponent: Float { Float(1.0 / value) }
}