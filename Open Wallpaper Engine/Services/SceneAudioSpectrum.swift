//
//  SceneAudioSpectrum.swift
//  系统音频捕获 + FFT，给音频响应类效果提供频谱数据。
//
//  macOS 14.2 起的 CoreAudio Process Tap：建全局 tap → 私有聚合设备 → IOProc 读交错 float32。
//  已验证：本机 48kHz / 2ch / float32 / interleaved，无需权限弹窗即可采集。
//

import Foundation
import CoreAudio
import AVFoundation
import Accelerate
import AppKit
import SpriteKit

final class SceneAudioSpectrum {

    static let shared = SceneAudioSpectrum()

    /// 16 段归一化频谱（0…1），左右声道各一份。WE 的音频效果读的就是这个形状。
    private(set) var left: [Float] = Array(repeating: 0, count: 32)
    private(set) var right: [Float] = Array(repeating: 0, count: 32)

    private let fftSize = 1024
    private let bands = 32

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private let lock = NSLock()

    private var ringL: [Float]
    private var ringR: [Float]
    private var writeIndex = 0

    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var timer: Timer?
    private var logTicks = 0
    /// 逐频段的历史峰值（自动增益用），缓慢衰减。
    private var peakL = [Float](repeating: 0.001, count: 32)
    private var peakR = [Float](repeating: 0.001, count: 32)

    private init() {
        ringL = Array(repeating: 0, count: 1024)
        ringR = Array(repeating: 0, count: 1024)
        window = Array(repeating: 0, count: 1024)
        let n = vDSP_Length(1024)
        if let setup = vDSP_create_fftsetup(vDSP_Length(log2(1024.0)), FFTRadix(kFFTRadix2)) {
            fftSetup = setup
        }
        vDSP_hann_window(&window, n, Int32(vDSP_HANN_NORM))
    }

    // MARK: - 启停

    func start() {
        guard !running else { return }
        guard buildTap() else { return }
        running = true
        // 每 33ms 更新一次频谱（约 30Hz，和壁纸帧率同量级）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.update()
            }
            if let t = self.timer { RunLoop.main.add(t, forMode: .common) }
        }
        NSLog("[Audio] spectrum capture started (tap %u)", tapID)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let proc = ioProcID, aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggID, proc)
            AudioDeviceDestroyIOProcID(aggID, proc)
            ioProcID = nil
        }
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        running = false
        NSLog("[Audio] spectrum capture stopped")
    }

    // MARK: - 建 tap

    private func buildTap() -> Bool {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tid = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tid) == noErr else {
            NSLog("[Audio] create tap failed")
            return false
        }
        tapID = tid

        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let uidErr = withUnsafeMutablePointer(to: &uid) { p in
            AudioObjectGetPropertyData(tid, &addr, 0, nil, &size, p)
        }
        guard uidErr == noErr else { NSLog("[Audio] read tap uid failed \(uidErr)"); return false }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "wallpaper-engine-audio",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: uid as String,
                 kAudioSubTapDriftCompensationKey as String: true]
            ]
        ]
        var aid = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aid) == noErr else {
            NSLog("[Audio] create aggregate failed")
            return false
        }
        aggID = aid

        let q = DispatchQueue(label: "scene.audio.tap")
        let err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aid, q) { [weak self] _, inData, _, _, _ in
            guard let self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = abl.first, let mData = first.mData else { return }
            let channels = max(Int(first.mNumberChannels), 1)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let ptr = mData.assumingMemoryBound(to: Float.self)
            self.lock.lock()
            for i in 0..<frames {
                self.ringL[self.writeIndex] = ptr[i * channels]
                self.ringR[self.writeIndex] = channels > 1 ? ptr[i * channels + 1] : ptr[i * channels]
                self.writeIndex = (self.writeIndex + 1) % 1024
            }
            self.lock.unlock()
        }
        guard err == noErr, let proc = ioProcID else {
            NSLog("[Audio] ioproc failed \(err)")
            return false
        }
        guard AudioDeviceStart(aid, proc) == noErr else {
            NSLog("[Audio] device start failed")
            return false
        }
        return true
    }

    // MARK: - FFT

    private func update() {
        guard let setup = fftSetup else { return }

        lock.lock()
        var snapL = Array(repeating: Float(0), count: fftSize)
        var snapR = Array(repeating: Float(0), count: fftSize)
        for i in 0..<fftSize {
            snapL[i] = ringL[(writeIndex + i) % fftSize]
            snapR[i] = ringR[(writeIndex + i) % fftSize]
        }
        lock.unlock()

        let newL = bandsOf(snapL, setup: setup)
        let newR = bandsOf(snapR, setup: setup)

        // 平滑，避免频谱抖动得太厉害
        for i in 0..<bands {
            left[i] = left[i] * 0.25 + newL[i] * 0.75
            right[i] = right[i] * 0.25 + newR[i] * 0.75
        }
        pushSpectrumFloats()
        logTicks += 1
        if logTicks % 60 == 0 {
            NSLog("[Audio] bands L=[%.2f %.2f %.2f %.2f] R0=%.2f", left[0], left[2], left[5], left[9], right[0])
        }
    }

    private func bandsOf(_ samples: [Float], setup: FFTSetup) -> [Float] {
        let n = vDSP_Length(fftSize)
        var buf = samples
        vDSP_vmul(buf, 1, window, 1, &buf, 1, n)

        let half = fftSize / 2
        var real = Array(repeating: Float(0), count: half)
        var imag = Array(repeating: Float(0), count: half)
        var mags = Array(repeating: Float(0), count: half)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        var out = Array(repeating: Float(0), count: bands)
        for b in 0..<bands {
            let lo = Int(Float(half) * powf(Float(b) / Float(bands), 1.6))
            let hi = max(lo + 1, Int(Float(half) * powf(Float(b + 1) / Float(bands), 1.6)))
            var sum: Float = 0
            for i in lo..<min(hi, half) { sum += mags[i] }
            // 对数压缩 + 放大，让安静的音乐也有可见响应
            out[b] = log10(1.0 + (sum / Float(max(hi - lo, 1))) * 60.0)
        }
        // 按全局峰值归一化（保留各段之间的高低差），再轻微提亮低段。
        // 注意：**不要**做逐段自动增益 —— 那会让每段都顶到 1.0，画面变成一整片。
        // 归一化后的指数由「敏感度」设置控制（Settings → Performance 的滑杆）：
        // 敏感度越高，指数越小，安静频段被抬得越高，画面越跳。
        let mx = out.max() ?? 0
        let e = SceneSensitivity.exponent
        if mx > 0 { out = out.map { min(pow($0 / mx, e), 1.0) } }
        return out
    }

    // MARK: - 供着色器使用的频谱纹理

    /// 16×2 纹理：第 0 行左声道、第 1 行右声道。
    /// SKUniform 不支持数组，所以频谱只能走纹理；着色器里用
    /// texture2D(u_spectrum, vec2((i + 0.5) / 16.0, 0.25)).r 取值。


    private var spectrumPacks: [SKUniform] = []

    /// 16 个 vec4：前 8 个左声道（32 段摊开）、后 8 个右声道。
    func register(spectrumPacks packs: [SKUniform]) {
        spectrumPacks = packs
        pushSpectrumFloats()
    }

    func makeSpectrumTextureForBinding() -> SKTexture? { makeSpectrumTexture() }

    private func makeSpectrumTexture() -> SKTexture? {
        let w = 16, h = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: w * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return nil }
        for row in 0..<h {
            let src = row == 0 ? left : right
            for x in 0..<w {
                let v = UInt8(max(0, min(1, src[x])) * 255)
                let o = row * rep.bytesPerRow + x * 4
                data[o] = v; data[o + 1] = v; data[o + 2] = v; data[o + 3] = 255
            }
        }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        return SKTexture(image: img)
    }

    /// 每次频谱更新后推给所有已注册的 uniform。
    private var pushLogTicks = 0

    private func pushSpectrumFloats() {
        guard spectrumPacks.count >= 16 else {
            pushLogTicks += 1
            if pushLogTicks % 60 == 0 { NSLog("[Audio] push skipped: only %d packs registered", spectrumPacks.count) }
            return
        }
        pushLogTicks += 1
        if pushLogTicks % 60 == 0 {
            NSLog("[Audio] push tick=%d left0=%.3f packX=%.3f", pushLogTicks, left[0], spectrumPacks[0].vectorFloat4Value.x)
        }
        for side in 0..<2 {
            let src = side == 0 ? left : right
            for p in 0..<8 {
                let base = p * 4
                spectrumPacks[side * 8 + p].vectorFloat4Value = vector_float4(
                    src[base], src[base + 1], src[base + 2], src[base + 3])
            }
        }
    }
}
