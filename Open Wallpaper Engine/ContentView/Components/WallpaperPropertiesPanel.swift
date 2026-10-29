//
//  WallpaperPropertiesPanel.swift
//  壁纸属性面板：按 project.json 的 general.properties 动态生成控件
//  对应正版 Wallpaper Engine 右侧 Properties 那一栏。
//  右栏太窄放不下（属性可能上百个），所以做成：行内摘要 + 独立可滚动面板。
//

import SwiftUI

// MARK: - 行内入口（塞在右栏 Properties 标题下）

struct WallpaperPropertiesPanel: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @State private var properties: [WEUserProperty] = []
    @State private var showSheet = false

    private var directory: URL { wallpaperViewModel.currentWallpaper.wallpaperDirectory }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(properties.isEmpty ? "No adjustable properties"
                                          : "\(properties.count) adjustable properties",
                      systemImage: "slider.horizontal.3")
                    .font(.callout)
                    .foregroundStyle(properties.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Edit…") { showSheet = true }
                    .disabled(properties.isEmpty)
            }
        }
        .onAppear { reload() }
        .onChange(of: directory) { _, _ in reload() }
        .sheet(isPresented: $showSheet) {
            WallpaperPropertiesSheet(
                wallpaperViewModel: wallpaperViewModel,
                directory: directory
            )
        }
    }

    private func reload() {
        properties = WallpaperProperties.load(from: directory)
    }
}

// MARK: - 独立属性面板（可滚动，容纳上百个属性）

struct WallpaperPropertiesSheet: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let directory: URL

    @State private var properties: [WEUserProperty] = []
    @State private var lastCommit: [String: Date] = [:]
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [WEUserProperty] {
        guard !query.isEmpty else { return properties }
        let q = query.lowercased()
        return properties.filter { $0.text.lowercased().contains(q) || $0.key.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(wallpaperViewModel.currentWallpaper.project.title)
                    .font(.headline).lineLimit(1)
                Spacer()
                Text("\(properties.count) properties")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter properties", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(8)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(filtered) { p in
                        PropertyRow(property: p) { newValue in
                            commit(newValue, for: p)
                        }
                        Divider()
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 520, height: 560)
        .onAppear { properties = WallpaperProperties.load(from: directory) }
    }

    private func commit(_ value: String, for p: WEUserProperty) {
        if let last = lastCommit[p.key], Date().timeIntervalSince(last) < 0.2 { return }
        lastCommit[p.key] = Date()

        guard WallpaperProperties.set(value, forKey: p.key, in: directory) else { return }
        if let i = properties.firstIndex(where: { $0.key == p.key }) {
            properties[i].value = value
        }
        var w = wallpaperViewModel.currentWallpaper
        if WallpaperProperties.reloadProject(of: &w) {
            wallpaperViewModel.currentWallpaper = w
        }
    }
}

// MARK: - 单行控件

private struct PropertyRow: View {
    let property: WEUserProperty
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(displayText)
                .font(.callout)
                .lineLimit(2)
                .frame(width: 190, alignment: .leading)

            Spacer(minLength: 8)

            control
        }
    }

    private var displayText: String {
        if property.text.hasPrefix("ui_") { return property.key }
        return property.text.isEmpty ? property.key : property.text
    }

    @ViewBuilder
    private var control: some View {
        if property.isColor {
            ColorPicker("", selection: Binding(
                get: { property.colorValue },
                set: { onChange(encodeColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()

        } else if property.isSlider {
            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { property.doubleValue },
                    set: { onChange(String(format: "%.4f", $0)) }
                ), in: property.sliderRange)
                .frame(width: 160)
                Text(String(format: "%.2f", property.doubleValue))
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }

        } else if property.isCombo, !property.options.isEmpty {
            Picker("", selection: Binding(
                get: { property.value },
                set: { onChange($0) }
            )) {
                ForEach(property.options, id: \.value) { o in
                    Text(o.label.isEmpty ? o.value : o.label).tag(o.value)
                }
            }
            .labelsHidden()
            .frame(width: 190)

        } else if property.isBool {
            Toggle("", isOn: Binding(
                get: { property.boolValue },
                set: { onChange($0 ? "1" : "0") }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

        } else {
            TextField("", text: Binding(
                get: { property.value },
                set: { onChange($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 190)
        }
    }

    private func encodeColor(_ c: Color) -> String {
        guard let srgb = NSColor(c).usingColorSpace(.sRGB) else { return "0 0 0" }
        return String(format: "%.5f %.5f %.5f",
                      srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
    }
}
