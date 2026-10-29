//
//  WallpaperProperties.swift
//  从 project.json 的 general.properties 读/写用户可调属性
//  正版 Wallpaper Engine 右侧那栏就是按这里的 type 动态生成控件的
//

import Foundation
import SwiftUI

/// 一个用户可调属性
struct WEUserProperty: Identifiable, Equatable {
    var key: String
    var type: String
    var text: String
    var value: String
    var options: [WEUserPropertyOption2]
    var order: Int

    var id: String { key }

    var isColor: Bool { type.lowercased() == "color" }
    var isSlider: Bool { type.lowercased() == "slider" }
    var isCombo: Bool { type.lowercased() == "combo" }
    var isBool: Bool { type.lowercased() == "bool" }

    var boolValue: Bool {
        let v = value.lowercased()
        return v == "1" || v == "true"
    }

    /// slider 区间：优先从 options 的第一项 "min max" 解析，否则 0...1
    var sliderRange: ClosedRange<Double> {
        if let opt = options.first {
            let parts = opt.value.split(separator: " ").compactMap { Double($0) }
            if parts.count >= 2, parts[0] < parts[1] { return parts[0]...parts[1] }
        }
        return 0...1
    }

    var doubleValue: Double { Double(value) ?? sliderRange.lowerBound }

    /// 颜色：WE 存 "r g b"（0...1）
    var colorValue: Color {
        let p = value.split(separator: " ").compactMap { Double($0) }
        guard p.count >= 3 else { return .gray }
        return Color(red: p[0], green: p[1], blue: p[2])
    }
}

struct WEUserPropertyOption2: Equatable, Hashable {
    var label: String
    var value: String
}

enum WallpaperProperties {

    /// 读取壁纸目录里 project.json 的 general.properties（排除 schemecolor，它由专门的取色器负责）
    static func load(from directory: URL) -> [WEUserProperty] {
        let url = directory.appending(path: "project.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let general = root["general"] as? [String: Any],
              let props = general["properties"] as? [String: Any]
        else { return [] }

        var out: [WEUserProperty] = []
        for (key, raw) in props {
            guard key != "schemecolor" else { continue }
            guard let dict = raw as? [String: Any] else { continue }
            let type = (dict["type"] as? String) ?? "text"
            // group / label 这类纯展示项不给控件
            if type.lowercased() == "group" { continue }

            var opts: [WEUserPropertyOption2] = []
            if let arr = dict["options"] as? [[String: Any]] {
                for o in arr {
                    opts.append(WEUserPropertyOption2(
                        label: (o["label"] as? String) ?? "",
                        value: (o["value"] as? String) ?? ""
                    ))
                }
            }
            out.append(WEUserProperty(
                key: key,
                type: type,
                text: (dict["text"] as? String) ?? key,
                value: encodeValue(dict["value"]),
                options: opts,
                order: (dict["order"] as? Int) ?? Int((dict["order"] as? Double) ?? 0)
            ))
        }
        return out.sorted { ($0.order, $0.key) < ($1.order, $1.key) }
    }

    /// 把 JSON 里的 value（可能是字符串/数字/布尔）统一成字符串
    private static func encodeValue(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let b as Bool: return b ? "1" : "0"
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let a as [Any]:
            return a.map { encodeValue($0) }.joined(separator: " ")
        default: return ""
        }
    }

    /// 只改这一个属性的 value，其余字段原样保留
    @discardableResult
    static func set(_ value: String, forKey key: String, in directory: URL) -> Bool {
        let url = directory.appending(path: "project.json")
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var general = root["general"] as? [String: Any],
              var props = general["properties"] as? [String: Any],
              var prop = props[key] as? [String: Any]
        else { return false }

        // 按原类型写回，避免把数字/布尔写成字符串
        let type = (prop["type"] as? String)?.lowercased() ?? "text"
        if type == "bool" {
            prop["value"] = (value == "1" || value.lowercased() == "true")
        } else if type == "slider", let d = Double(value) {
            prop["value"] = d
        } else {
            prop["value"] = value
        }
        props[key] = prop
        general["properties"] = props
        root["general"] = general

        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try out.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    /// 从磁盘重新解码壁纸工程（属性改完后用它刷新内存模型，触发渲染器重载）
    static func reloadProject(of wallpaper: inout WEWallpaper) -> Bool {
        let url = wallpaper.wallpaperDirectory.appending(path: "project.json")
        guard let data = try? Data(contentsOf: url),
              let project = try? JSONDecoder().decode(WEProject.self, from: data)
        else { return false }
        wallpaper.project = project
        return true
    }
}
