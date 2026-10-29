//
//  SceneExposure.swift
//  场景整体曝光（0.5–1.5，默认 1.0），独立 UserDefaults 键。
//  不放进 GlobalSettings：那是个 Codable 结构，加字段会让旧配置解码失败。
//

import Foundation

enum SceneExposure {
    static let defaultsKey = "SceneExposure"
    static let minimum = 0.5
    static let maximum = 1.5

    static var value: Double {
        get {
            guard let v = UserDefaults.standard.object(forKey: defaultsKey) as? Double else { return 1.0 }
            return min(maximum, max(minimum, v))
        }
        set {
            UserDefaults.standard.set(min(maximum, max(minimum, newValue)), forKey: defaultsKey)
        }
    }

    static var isNeutral: Bool { abs(value - 1.0) < 0.001 }
}
