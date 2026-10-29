//
//  PerformancePage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/12.
//

import SwiftUI

struct PerformancePage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    
    @State private var isEditingFPS = false
    @State private var exposure = SceneExposure.value
    @State private var renderScale = SceneRenderScale.current
    @State private var sensitivity = SceneSensitivity.value
    @State private var barHeight = SceneBarHeight.value
    @State private var particlesEnabled = SceneParticles.isEnabled
    @State private var particleDensity = SceneParticles.density
    @State private var approximateRefracting = SceneParticles.approximatesRefracting
    
    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    private var fpsOptions: [Int] {
        FrameRate.options(refresh: NSScreen.main?.maximumFramesPerSecond ?? 60)
    }

    /// What a scene actually runs at for the saved setting — a saved 16 is paced at 15.
    private var deliveredFPS: Int { FrameRate.deliverable(viewModel.settings.fps, on: nil) }

    /// The slider moves over the deliverable rates by index, so every stop is one of them.
    private var fpsStep: Binding<Double> {
        Binding(
            get: { Double(fpsOptions.firstIndex(of: deliveredFPS) ?? 0) },
            set: { index in
                let options = fpsOptions
                guard !options.isEmpty else { return }
                let i = min(max(Int(index.rounded()), 0), options.count - 1)
                viewModel.settings.fps = Double(options[i])
            })
    }
    
    var body: some View {
        Form {
            Section {
                Picker("Other Application Focused:", selection: $viewModel.settings.otherApplicationFocused) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Mute").tag(GSPlayback.mute)
                    Text("Pause").tag(GSPlayback.pause)
                }
                
                Picker("Other Application Fullscreen:", selection: $viewModel.settings.otherApplicationFullscreen) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Mute").tag(GSPlayback.mute)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }
                
                // Detected from Core Audio's process objects, which macOS 14.2 introduced; see
                // `OtherAppAudioMonitor` for what the signal means and what it excludes. It
                // releases several seconds after the other app goes quiet, because that is
                // how long the system keeps the app's output running after a pause. Below
                // 14.2 there is no per-process signal without a capture permission, so the
                // picker is bound to a constant there and a value saved on a newer system is
                // not displayed as if it were in force.
                if PlaybackConditionMonitor.canDetectOtherApplicationAudio {
                    Picker("Other Application Playing Audio:", selection: $viewModel.settings.otherApplicationPlayingAudio) {
                        Text("Keep Running").tag(GSPlayback.keepRunning)
                        Text("Mute").tag(GSPlayback.mute)
                        Text("Pause").tag(GSPlayback.pause)
                    }
                    .help("Applies while another app has an audio output open — usually while it plays, and a few seconds after. A page that keeps an output open silently (an idle Web Audio context, muted autoplay video) also counts, for as long as it stays open.")
                } else {
                    Picker("Other Application Playing Audio:", selection: .constant(GSPlayback.keepRunning)) {
                        Text("Keep Running").tag(GSPlayback.keepRunning)
                        Text("Mute").tag(GSPlayback.mute)
                        Text("Pause").tag(GSPlayback.pause)
                    }
                    .disabled(true)
                    .help("Requires macOS 14.2 or later, which is the first to report which apps are playing sound.")
                }
                
                Picker("Display asleep", selection: $viewModel.settings.displayAsleep) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }
                
                Picker("Laptop on battery", selection: $viewModel.settings.laptopOnBattery) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }
            } header: {
                Label("Playback", systemImage: "play.fill")
            }
            Section {
                Toggle("Show Particles", isOn: $particlesEnabled)
                    .onChange(of: particlesEnabled) { _, value in SceneParticles.isEnabled = value }
                    .help("Turn off to skip building every particle emitter in the scene — the biggest single CPU saving on heavy scenes.")
                Picker("Particle Density:", selection: $particleDensity) {
                    Text("Thin (0.5\u{00D7})").tag(0.5)
                    Text("Normal").tag(1.0)
                    Text("Rich (1.5\u{00D7})").tag(1.5)
                    Text("Dense (2\u{00D7})").tag(2.0)
                }
                .disabled(!particlesEnabled)
                .onChange(of: particleDensity) { _, value in SceneParticles.density = value }
                .help("Scales every emitter's birth rate. Lower is thinner and cheaper.")
                Picker("Refracting Particles:", selection: $approximateRefracting) {
                    Text("Soft Glow (approximation)").tag(true)
                    Text("Hide").tag(false)
                }
                .disabled(!particlesEnabled)
                .onChange(of: approximateRefracting) { _, value in SceneParticles.approximatesRefracting = value }
                .help("Refracting particles need the frame behind them, which SpriteKit cannot read. Soft Glow draws a generated bokeh dot instead of the blank placeholder texture; Hide drops them.")
            } header: {
                Label("Particles", systemImage: "sparkles")
                .onChange(of: viewModel.settings.activeQuality) { _, _ in
                    // 预设会改粒子的两个键，界面上的三个控件要跟着显示真实值。
                    particlesEnabled = SceneParticles.isEnabled
                    particleDensity = SceneParticles.density
                    approximateRefracting = SceneParticles.approximatesRefracting
                }
            } footer: {
                Text("Applies the next time a wallpaper loads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                // A selection, not four buttons: which preset is active is read back from the
                // settings (`GlobalSettings.activeQuality`), so the page shows what is running,
                // and moving any control below falls back to "Custom" rather than leaving a
                // preset lit that no longer describes it.
                HStack {
                    Picker("Preset", selection: Binding<GSQuality?>(
                        get: { viewModel.settings.activeQuality },
                        set: { if let preset = $0 { viewModel.setQuality(preset) } })) {
                        Text("Low").tag(GSQuality?.some(.low))
                        Text("Medium").tag(GSQuality?.some(.medium))
                        Text("High").tag(GSQuality?.some(.high))
                        Text("Ultra").tag(GSQuality?.some(.ultra))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if viewModel.settings.activeQuality == nil {
                        Text("Custom")
                            .foregroundStyle(.secondary)
                    }
                }
                // Effect chains on scene layers, rebuilt live. There is no Ultra: see
                // `GSPostProcessingQuality`.
                Picker("Post-Processing", selection: $viewModel.settings.postProcessing) {
                    Text("Disabled").tag(GSPostProcessingQuality.disabled)
                    Text("Enabled").tag(GSPostProcessingQuality.enabled)
                }
                .help("Shader effects on scene layers. Disabled draws the plain composite and costs far less on scenes that use many effects.")
                HStack {
                    Text("Exposure")
                    Spacer()
                    Slider(value: $exposure, in: SceneExposure.minimum...SceneExposure.maximum, step: 0.05) { editing in
                        if !editing {
                            SceneExposure.value = exposure
                            // 立即重载当前屏幕的壁纸，让新曝光生效
                            let vm = AppDelegate.shared.wallpaperViewModel
                            vm.setWallpaper(vm.currentWallpaper, for: vm.selectedScreenId)
                        }
                    }
                    .frame(width: 150)
                    Text(String(format: "%.2fx", exposure)).frame(width: 44).monospacedDigit()
                }
                .help("Scales the whole scene. Lower it when bright effects blow out to white.")
                HStack {
                    Text("Audio Bar Height")
                    Spacer()
                    Slider(value: $barHeight, in: SceneBarHeight.minimum...SceneBarHeight.maximum, step: 0.01) { editing in
                        if !editing { SceneBarHeight.value = barHeight }
                    }
                    .frame(width: 150)
                    Text(String(format: "%.0f%%", barHeight * 100)).frame(width: 44).monospacedDigit()
                }
                .help("How tall the audio bars grow, as a fraction of the wallpaper. Takes effect immediately.")
                HStack {
                    Text("Audio Sensitivity")
                    Spacer()
                    Slider(value: $sensitivity, in: SceneSensitivity.minimum...SceneSensitivity.maximum, step: 0.1) { editing in
                        if !editing { SceneSensitivity.value = sensitivity }
                    }
                    .frame(width: 150)
                    Text(String(format: "%.1fx", sensitivity)).frame(width: 44).monospacedDigit()
                }
                .help("How strongly the wallpaper reacts to music. Higher lifts quiet bands; takes effect immediately.")
                Picker("Wallpaper Render Scale", selection: $renderScale) {
                    ForEach(SceneRenderScale.allCases) { s in Text(s.title).tag(s) }
                }
                .onChange(of: renderScale) { _, newValue in
                    SceneRenderScale.current = newValue
                    let vm = AppDelegate.shared.wallpaperViewModel
                    vm.setWallpaper(vm.currentWallpaper, for: vm.selectedScreenId)
                }
                .help("Pixels the wallpaper is drawn at before the compositor scales it up. 1x halves fill cost; 2x is native sharpness.")
                Picker("Texture Resolution", selection: $viewModel.settings.textureResolution) {
                    Text("High Quality").tag(GSTextureResolutionQuality.highQuality)
                    Text("High Performance").tag(GSTextureResolutionQuality.highPerformance)
                    Text("Automatic").tag(GSTextureResolutionQuality.automatic)
                }
                .help("High Quality loads scene textures as authored. High Performance halves them. Automatic reduces each to what this display can show.")
                HStack {
                    Text("FPS")
                    Spacer()
                    // Steps through the rates the display can pace, and shows the one delivered.
                    // Any value used to be accepted, and SKView quietly ran something else.
                    Slider(value: fpsStep, in: 0...Double(max(fpsOptions.count - 1, 1)), step: 1)
                        .frame(width: 150)
                    if isEditingFPS {
                        TextField("FPS", text: Binding<String>(get: {
                            String(deliveredFPS)
                        }, set: {
                            if let newValue = Double($0) {
                                viewModel.settings.fps = Double(FrameRate.deliverable(newValue, on: nil))
                            }
                        }))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 50, height: 20)
                        .onSubmit {
                            isEditingFPS = false
                        }
                    } else {
                        Text(String(deliveredFPS))
                            .frame(width: 25)
                            .onTapGesture(count: 2) {
                                isEditingFPS = true
                            }
                    }
                }
                .overlay {
                    HStack {
                        Spacer(); Spacer()
                        if !isEditingFPS {
                            if deliveredFPS > 60 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .help("Above 60 FPS, scene wallpapers use far more energy and GPU time, which can slow down other apps and drain the battery.")
                            } else if deliveredFPS > 30 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help("Above 30 FPS, scene wallpapers use noticeably more energy and GPU time.")
                            }
                        }
                        Spacer()
                    }
                    
                }
                // Wallpaper Engine's layer-local "Reflection" effect, one more pass in a layer's
                // effect chain. Three scenes in the installed library use it (1990 Miata, BMW,
                // Lonely Cat), and it renders as their previews show since effect shaders run in
                // WE's top-down texture space. It is a pass like any other, so it only exists
                // while Post-Processing is on; the toggle is disabled otherwise, keeping its value
                // for when effects come back.
                HStack {
                    Text("Reflections")
                    Spacer()
                    Toggle("Reflection", isOn: $viewModel.settings.reflections)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                .disabled(viewModel.settings.postProcessing != .enabled)
                .help("Wallpaper Engine's reflection effect on scene layers. Requires Post-Processing.")
            } header: {
                Label("Quality", systemImage: "memorychip.fill")
                Text("These settings apply to scene wallpapers; FPS is also offered to web wallpapers.")
            }
        }
        .formStyle(.grouped)
    }
}
