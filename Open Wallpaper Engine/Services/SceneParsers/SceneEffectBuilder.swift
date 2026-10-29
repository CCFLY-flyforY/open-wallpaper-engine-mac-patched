//
//  SceneEffectBuilder.swift
//  Open Wallpaper Engine
//
//  Turns a layer's `effects` array into a chain of SpriteKit shaders.
//
//  Wallpaper Engine's effects are local to their layer, not post-processing over the composed
//  frame: 1682 of the 1764 effect passes in this library bind no texture beyond the layer they
//  are applied to. That is what makes a SpriteKit chain viable at all — nesting one
//  `SKEffectNode` per pass reproduces the structure without a render graph, render targets or a
//  second rasteriser.
//
//  Every stage fails safe. A shader that will not resolve, preprocess, translate or bind is
//  dropped and the layer draws exactly as it did before effects existed, so a wallpaper can
//  never be made worse by a pass this renderer does not understand.
//

import Cocoa
import SpriteKit

struct SceneEffectBuilder {
    /// Reads an asset. `bundle` is the effect's own directory, tried first, because an effect
    /// bundle's `materials/` and `shaders/` are relative to itself rather than to the wallpaper.
    let read: (_ path: String, _ bundle: String?) -> Data?
    let readTexture: (_ path: String, _ bundle: String?) -> NSImage?
    /// Settings → Reflections. Off drops every effect that runs Wallpaper Engine's `reflection`
    /// shader as if its author had switched it off: it is not counted in the tally, so the
    /// verification report shows exactly those passes gone (3 in the installed library: 1990
    /// Miata, BMW, Lonely Cat) and nothing reported as untranslatable that was not. It is the one
    /// effect with its own control because Wallpaper Engine's own settings give it one, and
    /// because it is a whole extra offscreen pass over a usually full-width layer.
    var reflections = true

    /// What happened, for the log and for the verification harness.
    struct Tally {
        var effects = 0
        var passes = 0
        var built = 0
        var unresolved = 0
        var untranslatable = 0

        static func + (a: Tally, b: Tally) -> Tally {
            Tally(effects: a.effects + b.effects, passes: a.passes + b.passes,
                  built: a.built + b.built, unresolved: a.unresolved + b.unresolved,
                  untranslatable: a.untranslatable + b.untranslatable)
        }
    }

    /// One translated pass, with what the rasterizer needs to know about its cost.
    struct Pass {
        let shader: SKShader
        /// The pass does not read the clock, so its output only changes when its input does.
        let isTimeInvariant: Bool
        /// The `name` the scene gave the effect this pass belongs to, which is what a script
        /// switches it by: `getEffect(name).visible`.
        var effect: String? = nil
    }

    /// Passes for one layer, innermost first.
    func chain(for object: WESceneObject, tally: inout Tally) -> [Pass] {
        var shaders: [Pass] = []
        for effect in object.effects ?? [] {
            guard effect.visible != false, let file = effect.file else { continue }

            let bundle = (file as NSString).deletingLastPathComponent
            let manifest = read(file, nil).flatMap { try? JSONDecoder().decode(WEEffectFile.self, from: $0) }
            if !reflections, let manifest,
               (manifest.passes ?? []).contains(where: { isReflection($0, bundle: bundle) }) {
                continue
            }
            tally.effects += 1
            guard let manifest else {
                tally.unresolved += 1
                continue
            }

            // Nesting SKEffectNodes hands each pass exactly one input: the output of the pass
            // inside it. That reproduces an effect faithfully only when the effect is a straight
            // chain, and most of Wallpaper Engine's multi-pass effects are not.
            //
            // Measured over the nine multi-pass effects in the shared asset library, eight of
            // them — blur, blurprecise, godrays, shine, localcontrast, motionblur, cursorripple,
            // glitter — end in a pass that binds *two* targets: the result they cast into a
            // buffer, and the untouched layer to composite it back over. Handed only the cast
            // result, that pass composites the frame against itself and paints it one colour,
            // which is what it did to four wallpapers before this guard existed. They need real
            // render targets with multiple inputs, which is a renderer this one is not.
            //
            // `refraction` is the exception and the reason this is a shape test rather than a
            // count: two passes, neither writing to a target, neither binding one. That is a
            // chain, and nesting reproduces it exactly.
            let passes = manifest.passes ?? []
            tally.passes += passes.count
            guard !passes.isEmpty, passes.allSatisfy(isChainable) else {
                tally.untranslatable += passes.count
                continue
            }
            for (index, pass) in passes.enumerated() {
                let config = index < (effect.passes?.count ?? 0) ? effect.passes?[index] : nil
                if var shader = build(pass: pass, config: config, bundle: bundle) {
                    shader.effect = effect.name
                    shaders.append(shader)
                    tally.built += 1
                } else {
                    tally.untranslatable += 1
                }
            }
        }
        return shaders
    }

    // MARK: - Audio visualiser canvases

    /// Whether a blank layer exists only as the canvas of an audio visualiser this renderer
    /// declines, so that drawing it would show the canvas instead of what is painted on it.
    ///
    /// An audio visualiser in Wallpaper Engine is a plain solid layer — almost always white, the
    /// editor's default — with a spectrum generator on it that throws the layer's pixels away
    /// and draws bars in their place. Those generators cannot run here (no audio capture, and
    /// SKUniform has no array form for the spectrum), so the pass is declined and the layer used
    /// to draw unprocessed: a bare white rectangle where the bars should be. Over the installed
    /// library that was 8 drawn solid layers in 7 scenes — Sunset on Station's white square in its
    /// music sign, Pixels' 500×100 slab, Lost Landscape's pair, Honkai's 600×600 square, Good
    /// rest, Apple Music's panel, and a dim one in Hacker Apartment — plus Apple Music's two
    /// flat-white textured squares. (Road Infinite, Other World and
    /// Final Demons carry the same canvas, but under a "musicplayers" group their author ships
    /// switched off, so it was never drawn.) In Wallpaper Engine itself, with nothing playing,
    /// these layers draw nothing at all, which is what not drawing them reproduces.
    ///
    /// The test is deliberately narrow, every condition measured against the library:
    /// - **A blank canvas only** — the caller asks only for solid layers and for textures that
    ///   are a single flat colour (`SceneWallpaperViewModel.isFlatColour`). The two textured
    ///   layers in the library that carry a generator are Apple Music's white rounded squares,
    ///   which pass that test; a textured layer that holds a picture keeps it, whatever is on
    ///   it. Over-drawing a blank canvas is a fidelity bug, losing a picture would be a worse one.
    /// - **A generator, not a modulator** — see `WEShaderTranslator.audioSpectrumGenerator`.
    ///   `pulse` and friends are declined too, but they act on artwork that is right to show.
    /// - **It replaces the layer's alpha.** Every generator here is a fork of `Simple_Audio_Bars`
    ///   and shares its `TRANSPARENCY` combo: `1` (replace, the default) sets alpha to the bar
    ///   coverage and `4` (intersect) multiplies by it, so at silence the plain bars draw
    ///   nothing. The `enhanced_simple_audio_bars` fork (Honkai, both Lost Landscape layers)
    ///   defaults `BAR_STYLE` to rounded bars, whose caps still show at silence as a row of
    ///   small dots — dropping the canvas loses those dots, which is far closer to the
    ///   wallpaper than the full white slab it replaces.
    ///   Preserve, add, subtract and opaque keep the canvas visible in Wallpaper Engine too, and
    ///   a generator without that combo is not understood well enough to hide anything for. Of
    ///   the 10 drawn canvases, 9 are on `1` and Hacker Apartment's is on `4`; none on others.
    /// - **It is actually declined.** If a generator ever builds — audio capture, array
    ///   uniforms — the canvas comes back with it.
    func isDeclinedAudioCanvas(_ object: WESceneObject) -> Bool {
        for effect in object.effects ?? [] {
            guard effect.visible != false, let file = effect.file,
                  let data = read(file, nil),
                  let manifest = try? JSONDecoder().decode(WEEffectFile.self, from: data) else {
                continue
            }
            let bundle = (file as NSString).deletingLastPathComponent
            for (index, pass) in (manifest.passes ?? []).enumerated() {
                let config = index < (effect.passes?.count ?? 0) ? effect.passes?[index] : nil
                // The substring test is only a cheap filter in front of the preprocessor: this
                // is asked of every textured layer with an effect, and nearly none qualify.
                guard let prepared = prepare(pass: pass, config: config, bundle: bundle),
                      prepared.fragment.contains("g_AudioSpectrum"),
                      let combos = WEShaderTranslator.audioSpectrumGenerator(
                        fragment: prepared.fragment,
                        overrides: prepared.combos,
                        include: { name in
                            source(named: "shaders/\(name)", bundle: bundle)
                                ?? source(named: name, bundle: bundle)
                        }),
                      let transparency = combos["TRANSPARENCY"],
                      transparency == 1 || transparency == 4 else { continue }
                let declined = !isChainable(pass)
                    || build(pass: pass, config: config, bundle: bundle) == nil
                if declined { return true }
            }
        }
        return false
    }

    /// Whether a pass runs Wallpaper Engine's `reflection` shader, by the shader its material
    /// names — the same name the effect bundle and its material are filed under in the shared
    /// asset library, and what a wallpaper bundling its own copy keeps.
    private func isReflection(_ pass: WEEffectFile.Pass, bundle: String) -> Bool {
        guard let materialPath = pass.material,
              let data = read(materialPath, bundle),
              let material = try? JSONDecoder().decode(WEMaterial.self, from: data),
              let shader = material.passes?.first?.shader else { return false }
        return (shader as NSString).lastPathComponent == "reflection"
    }

    /// Whether a pass can be reproduced by wrapping the layer in one more `SKEffectNode`: it
    /// draws where it stands rather than into a buffer, and reads nothing but what it is given.
    private func isChainable(_ pass: WEEffectFile.Pass) -> Bool {
        pass.target == nil && (pass.bind?.isEmpty ?? true)
    }

    // MARK: - One pass

    /// A pass's shader source and the combos it would be compiled with, before translation.
    private struct Prepared {
        let fragment: String
        let vertex: String?
        let textures: [String?]
        let combos: [String: Int]
    }

    private func prepare(pass: WEEffectFile.Pass,
                         config: WESceneEffectPass?,
                         bundle: String) -> Prepared? {
        guard let materialPath = pass.material,
              let materialData = read(materialPath, bundle),
              let material = try? JSONDecoder().decode(WEMaterial.self, from: materialData),
              let shaderName = material.passes?.first?.shader else { return nil }

        guard let fragment = source(of: shaderName, extension: "frag", bundle: bundle) else {
            return nil
        }
        let vertex = source(of: shaderName, extension: "vert", bundle: bundle)

        // Combos come from three places, in increasing priority: the shader's own `[COMBO]`
        // defaults (resolved inside the translator), the material, and the scene's instance.
        // A fourth is implicit: a sampler annotated with a `combo` switches it on merely by
        // having a texture assigned, which is how a mask enables `#if MASK` without any
        // wallpaper ever writing that key.
        let textures = slotTextures(scene: config?.textures,
                                    material: material.passes?.first?.textures)
        var combos = material.passes?.first?.combos ?? [:]
        for (key, value) in samplerCombos(in: fragment, textures: textures) {
            combos[key] = value
        }
        for (key, value) in config?.combos ?? [:] { combos[key] = value }
        return Prepared(fragment: fragment, vertex: vertex, textures: textures, combos: combos)
    }

    private func build(pass: WEEffectFile.Pass,
                       config: WESceneEffectPass?,
                       bundle: String) -> Pass? {
        guard let prepared = prepare(pass: pass, config: config, bundle: bundle) else { return nil }
        var (rawFragment, vertex, textures, combos) =
            (prepared.fragment, prepared.vertex, prepared.textures, prepared.combos)
        // 频谱是 16 段；如果 shader 按 32/64 段编译，每个频段会被复制 2/4 次，
        // 视觉上就是一条"平的"平台（用户实测反馈）。强制成 16 段版本，1:1 对上。
        if combos["RESOLUTION"] != nil, combos["RESOLUTION"] != 32 {
            NSLog("[SceneVM] [Audio] RESOLUTION %d -> 32", combos["RESOLUTION"] ?? 0)
            combos["RESOLUTION"] = 32
        }

        // 音频响应：SKUniform 不支持数组，把 g_AudioSpectrumXX[i] 改写成对 16x2 频谱纹理的采样。
        // 拿不到系统音频时纹理全 0 —— 对 pulse 这类调制器等于不响应，但图层本身照常绘制
        // （原先的实现是整条效果直接拒绝，那样音频壁纸会整个消失）。
        // RESOLUTION 决定 barFreq 的取值范围（16/32/64），我们只有 16 段，
        // 必须按它把下标缩放到 0…15，否则超出部分恒为 0（整条效果会完全看不见）。
        let resolution = combos["RESOLUTION"] ?? 16
        let fragment = Self.rewriteAudioSpectrum(rawFragment, resolution: resolution)

        guard let translated = WEShaderTranslator.translate(
            fragment: fragment,
            vertex: vertex,
            overrides: combos,
            include: { name in
                source(named: "shaders/\(name)", bundle: bundle)
                    ?? source(named: name, bundle: bundle)
            }
        ) else {
            // 诊断：翻译失败时把改写后的源码落盘，便于一对一复现
            NSLog("[SceneVM] [Audio] translate FAILED for effect pass; head: %.160@",
                  String(fragment.prefix(160)))
            try? fragment.write(toFile: "/tmp/we_fragment_failed.glsl", atomically: true, encoding: .utf8)
            return nil
        }

        guard let uniforms = bind(translated, config: config, textures: textures,
                                  bundle: bundle) else { return nil }

        var shaderSource = translated.source
        if shaderSource.contains("u_packL0") {
            // 【诊断】红 = u_BarCount/64，绿 = barVolume1
            if let r = shaderSource.range(of: "we_FragColor = vec4(finalColor, alpha)") {
                _ = r // 诊断已移除
            }
            // SKShader 不会为 sampler 自动生成声明，必须自己补 —— 但它不能进翻译器的输入，
            // 否则会被那条「未声明标识符」校验拒掉。所以补在**翻译之后**。
            // 不要手写 `uniform sampler2D` —— SpriteKit 最终编译成 Metal，uniform 由
            // `SKShader.uniforms` 数组注入；手写声明在 Metal 里是非法语法。
            try? shaderSource.write(toFile: "/tmp/we_final.glsl", atomically: true, encoding: .utf8)
        }
        let shader = SKShader(source: shaderSource)
        shader.uniforms = uniforms
        // SKShader.uniforms 的 setter 会复制对象，所以必须注册它自己持有的那批 ——
        // 直接按名字取，避免跨函数的临时状态。
        let owned = shader.uniforms.filter { $0.name.hasPrefix("u_pack") }
        if !owned.isEmpty {
            SceneAudioSpectrum.shared.register(spectrumPacks: owned)
            NSLog("[SceneVM] [Audio] spectrum packs bound to shader-owned uniforms (%d)", owned.count)
        }
        return Pass(shader: shader, isTimeInvariant: !translated.usesTime)
    }

    // MARK: - 音频频谱

    /// 把 `g_AudioSpectrum16Left[i]` 这类**数组 uniform 访问**改写成对一张 16×2 频谱纹理的采样。
    ///
    /// 为什么必须改：SpriteKit 的 `SKUniform` 没有数组形态，而 WE 的音频类着色器读的是
    /// `float g_AudioSpectrum16Left[16]`。纹理可以按任意下标采样，正好绕开这个限制。
    /// 纹理布局：第 0 行左声道、第 1 行右声道（见 `SceneAudioSpectrum.makeSpectrumTexture`）。
    static func rewriteAudioSpectrum(_ source: String, resolution: Int = 16) -> String {
        guard source.contains("AudioSpectrum") else { return source }

        // 先去掉数组 uniform 的声明行 —— SKUniform 没有数组形态，留着会让翻译器去绑一个不存在的数组。
        let kept = source.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("uniform"), t.contains("AudioSpectrum"), t.contains("[") { return false }
            if t.hasPrefix("#define"), t.contains("AudioSpectrum") { return false }
            return true
        }.joined(separator: "\n")

        // 纯 float uniform 方案：SKShader 会为 uniforms 数组里的每个 float 自动生成声明
        // （`u_tint` 就是这样工作的），而 sampler 不会 —— 所以频谱摊成 16 个 float，
        // 动态下标用「与常数比较」的条件求和展开。
        var spectrumFloats: [String] = []
        for i in 0..<16 {
            spectrumFloats.append("u_specL\(i)")
            spectrumFloats.append("u_specR\(i)")
        }
        let terms = (0..<16).map { k in
            "(abs(i - \(k).0) < 0.5) ? (right > 0.5 ? u_specR\(k) : u_specL\(k)) : 0.0"
        }.joined(separator: " + ")
        _ = terms // 仅用于保持上面的计算，实际表达式在使用处内联生成

        var out = ""
        let chars = Array(kept)
        var i = 0
        while i < chars.count {
            // 找到下一个 g_AudioSpectrum* 标识符
            guard let start = findIdentifier(chars, from: i) else {
                out.append(contentsOf: chars[i...])
                break
            }
            out.append(contentsOf: chars[i..<start.lowerBound])
            var j = start.upperBound
            // 跳过空白找方括号
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            guard j < chars.count, chars[j] == "[" else {
                // 裸标识符（如 `#define u_AudioSpectrumLeft g_AudioSpectrum64Left` 的宏体）：
                // 它自己没有下标可采，而那些宏的**使用处**已经被上面的分支改成采样调用了，
                // 所以这里替换成字面量即可 —— 留着会被翻译器当成未声明标识符而拒绝整条效果。
                // 若这个标识符是 `#define` 后面的**宏名**，不能替换（会变成 `#define 0.0 ...`）。
                // 裸标识符（宏体之类）没有下标可采样，替换成字面量；
                // 相关的 #define 行已经在过滤阶段整行删掉了，所以不会出现 `#define 0.0` 这种非法写法。
                out.append("0.0")
                i = start.upperBound
                continue
            }
            // 括号配对，取下标表达式
            var depth = 0
            var k = j
            var inner = ""
            while k < chars.count {
                let c = chars[k]
                if c == "[" { depth += 1; if depth == 1 { k += 1; continue } }
                if c == "]" { depth -= 1; if depth == 0 { break } }
                inner.append(c)
                k += 1
            }
            let name = String(chars[start.lowerBound..<start.upperBound])
            let call: String
            let row = name.lowercased().contains("right") ? "0.75" : "0.25"
            let count = name.contains("64") ? "64.0" : (name.contains("32") ? "32.0" : "16.0")
            // 内联展开：SpriteKit 只把 uniform 作为参数交给 main，自由函数里读不到（实测）。
            let idx = "((\(inner)) * (32.0 / \(Double(max(resolution, 32)))))"
            let chan = name.lowercased().contains("right") ? "R" : "L"
            let comps = ["x", "y", "z", "w"]
            let expanded = (0..<32).map { k -> String in
                let pack = k / 4, comp = comps[k % 4]
                return "(abs(\(idx) - \(k).0) < 0.5 ? u_pack\(chan)\(pack).\(comp) : 0.0)"
            }.joined(separator: " + ")
            call = "(\(expanded))"
            out.append(call)
            i = min(k + 1, chars.count)
        }
        // GLSL 不允许 float 与 int 取模（WE 的 HLSL 允许）。
        out = out.replacingOccurrences(of: "frequency % RESOLUTION",
                                       with: "int(frequency) % RESOLUTION")

        if let r = out.range(of: "void main") {
            _ = r
            return out
        }
        return out
    }

    /// 在字符数组里找下一个 `g_AudioSpectrum` 开头的标识符，返回它所在的区间。
    private static func findIdentifier(_ chars: [Character], from index: Int) -> Range<Int>? {
        let needles = [Array("g_AudioSpectrum"), Array("u_AudioSpectrum")]
        var i = index
        while i < chars.count {
            var hit: [Character]? = nil
            for n in needles where i + n.count <= chars.count {
                if Array(chars[i..<(i + n.count)]) == n { hit = n; break }
            }
            if let needle = hit {
                var end = i + needle.count
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
                    end += 1
                }
                return i..<end
            }
            i += 1
        }
        return nil
    }

    // MARK: - Shader source

    private func source(of shader: String, extension ext: String, bundle: String) -> String? {
        source(named: "shaders/\(shader).\(ext)", bundle: bundle)
    }

    /// Shader source, with line endings normalised at the point of reading.
    ///
    /// Wallpaper Engine ships these files CRLF, and `"\r\n"` is a single `Character` in Swift, so
    /// `split(separator: "\n")` returns the whole file as one line. Every line-based reader here
    /// silently sees nothing. `samplerCombos` below was the second place this bit: it never found
    /// the mask declaration, so `MASK` stayed off, and a painted tint that should have been
    /// confined to the mask flooded its entire layer with flat colour.
    private func source(named path: String, bundle: String) -> String? {
        guard let data = read(path, bundle),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Texture slots

    /// The texture assigned to each sampler slot: the scene's own choice where it made one, the
    /// material's where it did not, `nil` where neither did.
    ///
    /// The material is a real source and was never consulted. `waterripple` and `waterflow` name
    /// their normal or phase map in slot 2 *only* in the material — the shader's annotation for
    /// that slot carries a label and no default — so a scene that did not repeat the path had
    /// nothing to bind and the pass was declined. A `null` in the material is not an
    /// assignment; it is the material leaving that slot open, and both write one into slot 1:
    /// `waterripple`'s mask, whose `MASK` combo would switch on with no mask to read and confine
    /// the ripple to nothing, and `waterflow`'s flow map, whose annotation supplies
    /// `util/noflow`. So a null falls through to the annotated default exactly as an absent slot
    /// does. (`refraction` does the same, but is a multi-pass effect and declined before this.)
    private func slotTextures(scene: [String?]?, material: [String?]?) -> [String?] {
        let count = max(scene?.count ?? 0, material?.count ?? 0)
        return (0..<count).map { slot in
            let fromScene = scene.flatMap { $0.indices.contains(slot) ? $0[slot] : nil }
            let fromMaterial = material.flatMap { $0.indices.contains(slot) ? $0[slot] : nil }
            return fromScene ?? fromMaterial
        }
    }

    // MARK: - Combos implied by texture slots

    /// `uniform sampler2D g_Texture1; // {"combo":"MASK", ...}` — the combo is on when the scene
    /// assigned a texture to that slot. Read from the raw source, because this has to be settled
    /// before the conditionals are evaluated.
    private func samplerCombos(in fragment: String, textures: [String?]) -> [String: Int] {
        var out: [String: Int] = [:]
        for raw in fragment.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("uniform sampler2D g_Texture"),
                  let commentRange = line.range(of: "//") else { continue }
            let name = line.dropFirst("uniform sampler2D ".count)
                .prefix { $0 != ";" && !$0.isWhitespace }
            guard let slot = Int(name.dropFirst("g_Texture".count)) else { continue }
            guard let annotation = (try? JSONSerialization.jsonObject(
                with: Data(line[commentRange.upperBound...].trimmingCharacters(in: .whitespaces).utf8)))
                    as? [String: Any],
                  let combo = annotation["combo"] as? String else { continue }
            let assigned = textures.indices.contains(slot) && textures[slot] != nil
            out[combo] = assigned ? 1 : 0
        }
        return out
    }

    // MARK: - Uniform binding

    private func bind(_ translated: WEShaderTranslator.Result,
                      config: WESceneEffectPass?,
                      textures: [String?],
                      bundle: String) -> [SKUniform]? {
        var out: [SKUniform] = []

        if translated.source.contains("u_packL0") {
            // SpriteKit 的 buffer 上限是 31，32 个 float uniform 会超（实测报 out of bounds），
            // 所以 16 段打包成 4 个 vec4 × 2 声道 = 8 个 uniform。
            var packs: [SKUniform] = []
            for side in ["L", "R"] {
                for p in 0..<8 {
                    let u = SKUniform(name: "u_pack\(side)\(p)", vectorFloat4: vector_float4(0, 0, 0, 0))
                    packs.append(u)
                    out.append(u)
                }
            }
            // 注意：SKShader.uniforms 的 setter 会复制这些对象，改手上这批不影响着色器；
            // 真正的注册放在建好 shader 之后，按名字从 shader.uniforms 里取它自己那批。
            _ = packs
        }

        for uniform in translated.uniforms {
            // Resolution uniforms describe how much of a padded texture is real. Nothing here
            // pads, so every ratio the shaders compute from them has to come out as 1 — a zero
            // default would divide the layer's coordinates by zero and blank it.
            if uniform.name.hasPrefix("g_Texture"), uniform.name.hasSuffix("Resolution") {
                out.append(SKUniform(name: uniform.name,
                                     vectorFloat4: vector_float4(1, 1, 1, 1)))
                continue
            }

            var values = uniform.defaultValue
            if let override = value(for: uniform, in: config), !override.isEmpty {
                let padded = override.count >= values.count
                    ? Array(override.prefix(max(values.count, 1)))
                    : override + Array(repeating: 0, count: values.count - override.count)
                // A scalar written for a vector uniform fills it, as the annotations abbreviate.
                values = override.count == 1 && values.count > 1
                    ? Array(repeating: override[0], count: values.count)
                    : padded
            }



            // 让条之间出现空隙（默认 0.1 几乎贴着，看起来是一整片）。
            if uniform.name == "u_BarSpacing", values.first.map({ $0 < 0.45 }) == true {
                NSLog("[SceneVM] [Audio] u_BarSpacing %@ -> 0.5", String(describing: values))
                values = [0.5]
            }
            // 作者设的条高上限只有 4%（被菜单栏挡住），抬到能看见的范围。
            // 条高由 Settings → Performance 的滑杆控制（默认 0.15）。
            // 壁纸作者原本设的是 0.04（只有 4%，被菜单栏挡住，什么都看不见），所以这里由用户接管。
            if uniform.name == "u_BarBounds", values.count >= 2 {
                let h = Float(SceneBarHeight.value)
                if values[1] != h { NSLog("[SceneVM] [Audio] u_BarBounds %@ -> [0.0, %.2f]", String(describing: values), h) }
                values = [0.0, h]
            }
            if uniform.name.contains("BarBounds") || uniform.name.contains("BarOpacity") || uniform.name.contains("BarCount") || uniform.name.contains("BarSpacing") {
                NSLog("[SceneVM] [Audio] %@ override=%@ final=%@ key=%@",
                      uniform.name,
                      String(describing: value(for: uniform, in: config)),
                      String(describing: values),
                      uniform.materialKey ?? uniform.label ?? "-")
            }
            switch uniform.kind {
            case .float, .int:
                out.append(SKUniform(name: uniform.name, float: values.first ?? 0))
            case .vec2:
                out.append(SKUniform(name: uniform.name,
                                     vectorFloat2: vector_float2(values[0], values[1])))
            case .vec3:
                out.append(SKUniform(name: uniform.name,
                                     vectorFloat3: vector_float3(values[0], values[1], values[2])))
            case .vec4:
                out.append(SKUniform(name: uniform.name,
                                     vectorFloat4: vector_float4(values[0], values[1],
                                                                 values[2], values[3])))
            case .mat4, .sampler2D:
                // A matrix uniform here can only be the model-view-projection the vertex stage
                // used, which this renderer does not reproduce; a shader that still reads one
                // after translation is not one we can honour.
                return nil
            }
        }

        for sampler in translated.samplers {
            guard let slot = sampler.textureSlot, slot != 0 else { continue }
            let path = textures.indices.contains(slot) ? textures[slot] : nil
            // No invented inputs. If a slot the shader actually reads has neither a texture the
            // scene assigned nor the neutral one its annotation names, there is nothing honest
            // to bind: a blend or overlay effect handed a blank second image paints the layer
            // flat, which is how an X-ray wallpaper went from a full picture to one colour.
            // Declining leaves the layer untouched, which is always a legitimate result.
            guard let image = path.flatMap({ readTexture($0, bundle) })
                    ?? sampler.defaultTexture.flatMap({ readTexture($0, bundle) }) else {
                return nil
            }
            out.append(SKUniform(name: sampler.name, texture: SKTexture(image: image)))
        }

        return out
    }

    private func value(for uniform: WEShaderUniform, in config: WESceneEffectPass?) -> [Float]? {
        guard let values = config?.constantshadervalues else { return nil }
        if let key = uniform.materialKey, let v = values[key] { return v.components }
        if let label = uniform.label, let v = values[label] { return v.components }
        return nil
    }

}
