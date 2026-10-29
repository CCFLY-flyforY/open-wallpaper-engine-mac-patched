# Modifications Notice

This repository is a **GPL-3.0** derivative of [Open Wallpaper Engine](https://github.com/Unayung/wallpaper-engine-mac)
(PR #7 branch, "scene wallpaper rendering"), which is itself a fork of
[MrWindDog/wallpaper-engine-mac](https://github.com/MrWindDog/wallpaper-engine-mac), originally created by
[Haren Chen](https://github.com/haren724). All upstream copyright remains with its authors.

In accordance with GPL-3.0 section 5(a), this file records the modifications made here.

## Date

2026-10-28 / 2026-10-29

## What was changed

### Modified files

| File | Change |
| --- | --- |
| `Services/SceneWallpaperViewModel.swift` | Composelayer effects are now built (previously skipped); particles honour the new user settings; refracting particles degrade to a generated bokeh sprite instead of being dropped |
| `Services/SceneParsers/SceneEffectBuilder.swift` | Audio-spectrum uniforms inlined into `main`, packed into `vec4` (SpriteKit caps uniform buffers at 31); resolution scaling; bar bounds driven by a user setting |
| `Services/SceneParsers/WEShaderTranslator.swift` | Declares the audio uniform names; stage logging for translation failures |
| `Services/GlobalSettingsService.swift` | Quality presets now also set particle enable/density |
| `SettingsView/PerformancePage.swift` | Exposure, audio bar height / sensitivity, and particle controls |
| `WallpaperView/SceneWallpaperView.swift` | Starts system-audio spectrum capture; adds an occlusion gate so a hidden wallpaper stops rendering |
| `ContentView/Components/WallpaperPreview.swift` | Preview sizing fix |

### Added files

| File | Purpose |
| --- | --- |
| `Services/WallpaperProperties.swift` | Reads `general.properties` from a project (the upstream model only decoded `schemecolor`) |
| `ContentView/Components/WallpaperPropertiesPanel.swift` | Sheet for editing those properties |
| `Services/SceneAudioSpectrum.swift` | CoreAudio process tap → FFT → per-band spectrum for audio-reactive scene shaders |
| `Services/SceneExposure.swift` | Exposure setting, stored in its own `UserDefaults` key |
| `Services/SceneRenderScale.swift` | Render-scale setting |
| `Services/SceneBarHeight.swift` | Audio bar height setting |
| `Services/SceneSensitivity.swift` | Audio sensitivity setting |
| `Services/SceneParticles.swift` | Particle enable / density / refracting-mode settings |

## What this repository does NOT contain

- No Wallpaper Engine application files, workshop content, or its shared `assets/` library
  (shaders, materials, particles). Scene wallpapers only reference those; the app reads them from a
  locally installed Wallpaper Engine copy, which the user must obtain separately.
- No code from the proprietary Windows implementation. The scene renderer here is an independent
  SpriteKit-based reimplementation written by the upstream project, not decompiled code.

## Trademark

"Wallpaper Engine" is a product of its respective owners. This project is not affiliated with,
endorsed by, or sponsored by them. It reads the file format so that assets a user already owns can
be rendered on macOS.
