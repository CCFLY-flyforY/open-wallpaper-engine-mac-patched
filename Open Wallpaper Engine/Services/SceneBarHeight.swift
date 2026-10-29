//
//  SceneBarHeight.swift
//  音频频谱条的高度上限（占画布高度的比例，0.02–0.5，默认 0.15）。
//  存在独立 UserDefaults 键里，实时生效。
//

import Foundation

enum SceneBarHeight {
    static let defaultsKey = "SceneBarHeight"
    static let minimum = 0.01
    static let maximum = 0.35

    static var value: Double {
        get {
            guard let v = UserDefaults.standard.object(forKey: defaultsKey) as? Double else { return 0.06 }
            return min(maximum, max(minimum, v))
        }
        set { UserDefaults.standard.set(min(maximum, max(minimum, newValue)), forKey: defaultsKey) }
    }
}