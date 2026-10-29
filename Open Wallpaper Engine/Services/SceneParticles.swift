//
//  SceneParticles.swift
//  粒子效果的三个用户开关：总开关 / 密度倍率 / 折射粒子的处理方式。
//  都存在独立 UserDefaults 键里（不放进 GlobalSettings 那个 Codable 结构，免得旧配置解码失败）。
//  取值在被构建时读取，所以改动要重载壁纸才生效。
//

import Foundation

enum SceneParticles {
    static let enabledKey = "SceneParticlesEnabled"
    static let densityKey = "SceneParticleDensity"
    static let refractingKey = "SceneParticleRefracting"

    static let densityMinimum = 0.25
    static let densityMaximum = 3.0

    /// 总开关。默认开 —— 关掉是整个场景不再建任何粒子发射器。
    static var isEnabled: Bool {
        get {
            guard let v = UserDefaults.standard.object(forKey: enabledKey) as? Bool else { return true }
            return v
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 出生率倍率（也乘到粒子总量上）。0.25 是"稀薄"，3 是"浓密"。
    static var density: Double {
        get {
            guard let v = UserDefaults.standard.object(forKey: densityKey) as? Double else { return 1.0 }
            return min(densityMaximum, max(densityMinimum, v))
        }
        set { UserDefaults.standard.set(min(densityMaximum, max(densityMinimum, newValue)), forKey: densityKey) }
    }

    /// 折射粒子（REFRACT 材质）怎么处理：
    /// true（默认）= 降级成程序生成的柔光圆点，至少能看到气泡在漂；
    /// false = 直接不建 —— SpriteKit 读不到节点背后的帧，硬画会变成几百个灰方块。
    static var approximatesRefracting: Bool {
        get {
            guard let v = UserDefaults.standard.object(forKey: refractingKey) as? Bool else { return true }
            return v
        }
        set { UserDefaults.standard.set(newValue, forKey: refractingKey) }
    }
}