//
//  SceneRenderScale.swift
//  壁纸渲染倍率的设置（独立 UserDefaults 键，不放进 GlobalSettings —— 那是 Codable 结构）。
//
//  原理：Retina 上按 2x 全量填充意味着每次绘制 800 万像素，SpriteKit 和 WindowServer 两边都吃。
//  按 1x 渲染再让合成器放大，填充量减半，实测合计 CPU 降约三成；代价是壁纸略微变软。
//

import Foundation

enum SceneRenderScale: String, CaseIterable, Identifiable {
    case quality      // 2x — 原生像素，最锐
    case balanced     // 1.5x — 折中
    case performance  // 1x — 填充量减半

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .quality: return 2.0
        case .balanced: return 1.5
        case .performance: return 1.0
        }
    }

    var title: String {
        switch self {
        case .quality: return "Quality (2x)"
        case .balanced: return "Balanced (1.5x)"
        case .performance: return "Performance (1x)"
        }
    }

    static let defaultsKey = "SceneRenderScale"

    static var current: SceneRenderScale {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let v = SceneRenderScale(rawValue: raw) else { return .balanced }
            return v
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
