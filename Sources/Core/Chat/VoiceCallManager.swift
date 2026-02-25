// VoiceCallManager.swift
// ZipherX
//
// FIX #1540: Voice call over encrypted P2P chat
// Audio-only calls through Tor .onion hidden services.
// Uses AVAudioEngine for capture/playback + AAC-ELD codec (built-in, no external deps).
// Audio frames encrypted with existing ChaChaPoly session keys from chat E2E.
//
// Architecture:
//   AVAudioEngine input → AAC-ELD encode → base64 → ChaChaPoly encrypt → TCP .onion
//   TCP .onion → ChaChaPoly decrypt → base64 decode → AAC-ELD decode → AVAudioEngine output
//
// Bandwidth: ~16 KB/s per direction (25 frames/s × ~640 bytes/frame as Int16 PCM)
// FIX #1573: Reduced from ~85 KB/s (Float32 50fps) — Tor can't sustain that.
// Latency: 400-800ms over Tor (3 hops), usable for conversation with jitter buffer

import Foundation
import AVFoundation
import Combine
#if os(iOS)
import AudioToolbox
#endif

/// FIX #1540: Manages voice calls over encrypted P2P chat
@MainActor
final class VoiceCallManager: ObservableObject {

    static let shared = VoiceCallManager()

    // MARK: - Published State

    @Published var callState: VoiceCallState = .idle
    @Published var callDuration: TimeInterval = 0
    @Published var isMuted: Bool = false
    @Published var isSpeakerOn: Bool = false
    @Published var remotePeerOnionAddress: String?

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var playerNode: AVAudioPlayerNode?
    private var hasTapInstalled: Bool = false  // FIX #1573: Track tap to prevent orphaned taps

    // MARK: - Call State

    private var currentCallId: String?
    private var callStartTime: Date?
    private var callDurationTimer: Timer?
    private var ringTimeoutTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?

    // MARK: - Jitter Buffer

    /// Adaptive jitter buffer for incoming audio frames
    /// Target: 80ms (4 frames), Max: 200ms (10 frames), Min: 40ms (2 frames)
    private var jitterBuffer: [UInt32: Data] = [:]  // seq → decoded audio
    private var nextPlaybackSeq: UInt32 = 0
    private var jitterTargetFrames: Int = 4  // 80ms at 20ms/frame
    private let jitterMinFrames: Int = 2     // 40ms
    private let jitterMaxFrames: Int = 10    // 200ms
    private var consecutiveLosses: Int = 0
    private var consecutiveSuccesses: Int = 0

    // MARK: - Audio Format

    private let sampleRate: Double = 16000    // 16kHz mono
    private let frameDurationMs: Int = 20     // 20ms per frame
    private let channels: AVAudioChannelCount = 1
    private let bitrate: Int = 16000          // 16kbps target

    // MARK: - Sequence

    private var sendSequence: UInt32 = 0
    nonisolated(unsafe) private var tapCallbackCount: Int = 0  // FIX #1573: Frame rate limiter (audio thread)

    // FIX #1552: Cooldown to prevent rapid-fire call attempts when peer is offline
    private var lastCallEndTime: Date?
    private let callCooldownSeconds: TimeInterval = 2.0

    // MARK: - Ringtone (FIX #1563)
    // Programmatically generated sine wave tones — no sound file dependencies.
    // Incoming: double-beep pattern (800Hz+1000Hz) alerting receiver.
    // Outgoing: ringback tone (440Hz+480Hz) for caller while waiting.

    private var ringtonePlayer: AVAudioPlayer?
    #if os(iOS)
    private var vibrationTimer: Timer?
    #endif

    // MARK: - Codec

    private var encoder: AVAudioConverter?
    private var decoder: AVAudioConverter?

    private init() {}

    // MARK: - Public API

    /// Initiate a voice call to a chat peer
    func startCall(to onionAddress: String) async -> Bool {
        guard callState == .idle else {
            print("📞 FIX #1540: Cannot start call — already in state \(callState)")
            return false
        }

        // FIX #1552: Cooldown to prevent rapid-fire calls when peer is offline.
        // Each failed call attempt takes ~300ms to detect and cleanup. Without cooldown,
        // user tapping call button repeatedly overwhelms the signaling path.
        if let lastEnd = lastCallEndTime, Date().timeIntervalSince(lastEnd) < callCooldownSeconds {
            print("📞 FIX #1552: Call cooldown active — wait \(String(format: "%.1f", callCooldownSeconds))s between attempts")
            return false
        }

        // FIX #1540: Request microphone permission before initiating call
        #if os(iOS)
        let micPermission = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micPermission else {
            print("📞 FIX #1540: Microphone permission denied — cannot start call")
            return false
        }
        #else
        // macOS: TCC requires NSMicrophoneUsageDescription + com.apple.security.device.audio-input entitlement
        // FIX #1567: Don't block call initiation on mic denial — allow listen-only mode.
        // Mic permission prompt will appear on first use after entitlement is added.
        let macMicResult = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        if !macMicResult {
            print("📞 FIX #1567: Microphone permission denied (macOS) — call will proceed in listen-only mode")
        }
        #endif

        let callId = UUID().uuidString
        currentCallId = callId
        remotePeerOnionAddress = onionAddress
        callState = .offering(callId: callId)
        sendSequence = 0

        // Send call offer
        let offer = CallOffer(
            callId: callId,
            codec: "aac-eld",
            sampleRate: Int(sampleRate),
            channels: Int(channels),
            frameDurationMs: frameDurationMs,
            bitrate: bitrate
        )

        guard let offerJSON = try? JSONEncoder().encode(offer),
              let offerString = String(data: offerJSON, encoding: .utf8) else {
            callState = .idle
            return false
        }

        // Send via ChatManager
        await ChatManager.shared.sendCallSignal(
            type: .callOffer,
            content: offerString,
            to: onionAddress
        )

        print("📞 FIX #1540: Call offer sent to \(onionAddress.prefix(16))... callId=\(callId.prefix(8))")

        // FIX #1563: Play ringback tone while waiting for answer
        startRingtone(isIncoming: false)

        // Start 30s ring timeout
        // FIX #1575: Use try/catch — try? swallows CancellationError, causing cancelled task
        // to continue executing and call endCall("timeout") at the exact moment peer accepts
        ringTimeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return  // Task was cancelled (call answered/ended) — do NOT call endCall
            }
            if case .offering = callState {
                print("📞 FIX #1540: Call offer timed out (30s)")
                await endCall(reason: "timeout")
            }
        }

        return true
    }

    /// Accept an incoming call
    func acceptCall() async {
        guard case .ringing(let callId) = callState else { return }

        // FIX #1563: Stop ringtone before starting audio session
        stopRingtone()

        // Send call answer
        let answer = CallAnswer(callId: callId, codec: "aac-eld")
        guard let answerJSON = try? JSONEncoder().encode(answer),
              let answerString = String(data: answerJSON, encoding: .utf8),
              let peer = remotePeerOnionAddress else { return }

        await ChatManager.shared.sendCallSignal(
            type: .callAnswer,
            content: answerString,
            to: peer
        )

        // Start audio session
        await beginAudioSession(callId: callId)
    }

    /// Decline an incoming call
    func declineCall() async {
        guard case .ringing(let callId) = callState else { return }
        await endCall(reason: "declined")
        print("📞 FIX #1540: Call declined — callId=\(callId.prefix(8))")
    }

    /// End current call (hang up)
    /// FIX #1552: Added re-entry guard to prevent recursive endCall cascade.
    /// Previous bug: sendCallSignal(call_end) fails → calls endCall(network_error)
    /// → sends another call_end → fails → calls endCall again → infinite loop.
    /// Now: if already .ending or .idle, skip immediately.
    func endCall(reason: String? = nil) async {
        // FIX #1552: Re-entry guard — prevent recursive cascade
        switch callState {
        case .ending:
            print("📞 FIX #1552: endCall skipped — already ending")
            return
        case .idle:
            print("📞 FIX #1552: endCall skipped — already idle")
            return
        default:
            break
        }

        let callId = currentCallId ?? "unknown"
        print("📞 FIX #1540: Ending call — callId=\(callId.prefix(8)), reason=\(reason ?? "user")")

        // Set ending state FIRST to block re-entry
        callState = .ending

        // FIX #1552: Save peer address before cleanup clears it
        let peerAddress = remotePeerOnionAddress

        // FIX #1552: Send call_end signal in a fire-and-forget manner.
        // Don't await — if peer is offline, sendCallSignal blocks or fails and
        // the error handler recursively calls endCall, causing the stuck "Ending call" UI.
        let control = CallControl(callId: callId, reason: reason)
        if let controlJSON = try? JSONEncoder().encode(control),
           let controlString = String(data: controlJSON, encoding: .utf8),
           let peer = peerAddress {
            Task {
                await ChatManager.shared.sendCallSignal(
                    type: .callEnd,
                    content: controlString,
                    to: peer
                )
            }
        }

        // Cleanup immediately — don't wait for signal delivery
        stopRingtone()  // FIX #1563: Stop any ringtone/vibration
        stopAudioSession()
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        callDurationTimer?.invalidate()
        callDurationTimer = nil
        currentCallId = nil
        callStartTime = nil
        callDuration = 0
        remotePeerOnionAddress = nil
        isMuted = false
        isSpeakerOn = false
        jitterBuffer.removeAll()
        sendSequence = 0
        tapCallbackCount = 0
        nextPlaybackSeq = 0
        consecutiveLosses = 0
        consecutiveSuccesses = 0
        jitterTargetFrames = 4

        // FIX #1552: Record end time for cooldown
        lastCallEndTime = Date()

        callState = .idle
    }

    /// Toggle microphone mute
    func toggleMute() {
        isMuted.toggle()
        // Muting doesn't stop capture — just stops sending frames
        print("📞 FIX #1540: Mute \(isMuted ? "ON" : "OFF")")
    }

    /// Toggle speaker output
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
        #endif
        print("📞 FIX #1540: Speaker \(isSpeakerOn ? "ON" : "OFF")")
    }

    // MARK: - Incoming Signal Handlers (called by ChatManager)

    /// Handle incoming call offer
    func handleCallOffer(_ offer: CallOffer, from onionAddress: String) {
        guard callState == .idle else {
            // Already in a call — auto-reject
            Task {
                let control = CallControl(callId: offer.callId, reason: "busy")
                if let json = try? JSONEncoder().encode(control),
                   let str = String(data: json, encoding: .utf8) {
                    await ChatManager.shared.sendCallSignal(type: .callReject, content: str, to: onionAddress)
                }
            }
            print("📞 FIX #1540: Rejecting call from \(onionAddress.prefix(16))... — busy")
            return
        }

        currentCallId = offer.callId
        remotePeerOnionAddress = onionAddress
        callState = .ringing(callId: offer.callId)

        print("📞 FIX #1540: Incoming call from \(onionAddress.prefix(16))... callId=\(offer.callId.prefix(8))")

        // FIX #1563: Play incoming ringtone + vibrate (iOS)
        startRingtone(isIncoming: true)

        // Auto-reject after 30s if not answered
        // FIX #1575: Use try/catch — try? swallows CancellationError (same bug as outgoing)
        ringTimeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return  // Task was cancelled (call accepted/declined) — do NOT call endCall
            }
            if case .ringing = callState {
                print("📞 FIX #1540: Incoming call timed out (30s)")
                await endCall(reason: "timeout")
            }
        }
    }

    /// Handle call answer (peer accepted)
    func handleCallAnswer(_ answer: CallAnswer) async {
        guard case .offering(let callId) = callState, answer.callId == callId else { return }

        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil

        // FIX #1563: Stop ringback tone — audio session takes over
        stopRingtone()

        print("📞 FIX #1540: Call answered — starting audio session")
        await beginAudioSession(callId: callId)
    }

    /// Handle call reject (peer declined)
    func handleCallReject(_ control: CallControl) async {
        guard currentCallId == control.callId else { return }
        print("📞 FIX #1540: Call rejected — reason: \(control.reason ?? "unknown")")
        await endCall(reason: control.reason)
    }

    /// Handle call end (peer hung up)
    func handleCallEnd(_ control: CallControl) async {
        guard currentCallId == control.callId else { return }
        print("📞 FIX #1540: Peer ended call — reason: \(control.reason ?? "hangup")")
        await endCall(reason: control.reason)
    }

    /// Handle incoming audio frame
    func handleAudioFrame(_ frame: CallAudioFrame) {
        guard case .active(let callId) = callState, frame.callId == callId else { return }

        // Decode base64 audio data
        guard let audioData = Data(base64Encoded: frame.opus) else { return }

        // Add to jitter buffer
        jitterBuffer[frame.seq] = audioData

        // Adaptive jitter: track losses and successes
        if frame.seq == nextPlaybackSeq {
            consecutiveSuccesses += 1
            consecutiveLosses = 0
            // Shrink buffer after 20 consecutive successes
            if consecutiveSuccesses >= 20 && jitterTargetFrames > jitterMinFrames {
                jitterTargetFrames -= 1
                consecutiveSuccesses = 0
            }
        } else if frame.seq > nextPlaybackSeq {
            // Gap detected
            consecutiveLosses += 1
            consecutiveSuccesses = 0
            // Grow buffer after 3 consecutive losses
            if consecutiveLosses >= 3 && jitterTargetFrames < jitterMaxFrames {
                jitterTargetFrames += 1
                consecutiveLosses = 0
            }
        }

        // FIX #1546: Wait until we have enough frames buffered before first drain
        // Without this, we drain immediately on seq=0 with no lookahead → choppy/silent
        if jitterBuffer.count >= jitterTargetFrames || frame.seq >= nextPlaybackSeq + UInt32(jitterTargetFrames) {
            drainJitterBuffer()
        }
    }

    // MARK: - Audio Session Management

    private func beginAudioSession(callId: String) async {
        // FIX #1540: Request microphone permission BEFORE touching AVAudioEngine.
        // Accessing engine.inputNode without permission is a guaranteed crash on iOS.
        #if os(iOS)
        let micPermission = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micPermission else {
            print("📞 FIX #1540: Microphone permission denied — cannot start call")
            await endCall(reason: "mic_denied")
            return
        }
        #else
        // macOS: TCC requires NSMicrophoneUsageDescription + com.apple.security.device.audio-input entitlement
        // FIX #1567: Don't end call on mic denial — proceed in listen-only mode.
        // The user can still hear the remote peer. Common on first launch before granting permission.
        let macMicPermission = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        let micAvailable = macMicPermission
        if !micAvailable {
            print("📞 FIX #1567: Microphone permission denied (macOS) — proceeding in listen-only mode")
        }
        #endif

        // FIX #1573: Do NOT set callState = .active here. Setting it before engine.start()
        // causes incoming audio frames to fill the jitter buffer while drainJitterBuffer
        // returns early (engine not running). Moved to after engine.start() succeeds.

        // Configure audio session
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setPreferredSampleRate(sampleRate)
            try session.setPreferredIOBufferDuration(Double(frameDurationMs) / 1000.0)
            try session.setActive(true)
        } catch {
            print("📞 FIX #1540: Audio session setup failed: \(error)")
            await endCall(reason: "audio_error")
            return
        }
        #endif

        // Setup audio engine
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else {
            await endCall(reason: "audio_error")
            return
        }

        engine.attach(player)

        // FIX #1573: Pass explicit 16kHz mono format to engine.connect().
        // With format:nil, the connection uses hardware rate (44.1/48kHz stereo).
        // When drainJitterBuffer schedules 16kHz mono buffers, the format mismatch
        // causes AVAudioEngine to silently drop every buffer — both sides hear nothing.
        // Passing the explicit format makes AVAudioEngine insert an automatic
        // sample-rate converter at the connection point (16kHz mono → hardware rate).
        guard let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            print("📞 FIX #1573: Failed to create playback format")
            await endCall(reason: "audio_error")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        // FIX #1546: Ensure output volume is at maximum
        player.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
            player.play()
        } catch {
            print("📞 FIX #1540: Audio engine start failed: \(error)")
            await endCall(reason: "audio_error")
            return
        }

        // FIX #1573: Set .active AFTER engine starts — audio frames arriving before
        // engine.isRunning are dropped by drainJitterBuffer's guard.
        callState = .active(callId: callId)
        callStartTime = Date()

        // FIX #1567: Skip microphone input entirely if permission denied (macOS listen-only mode)
        #if os(macOS)
        let shouldCapture = micAvailable
        #else
        let shouldCapture = true
        #endif

        if shouldCapture {
            // FIX #1541: Wait for input hardware to initialize before installing tap.
            // On iOS, engine.inputNode.inputFormat(forBus: 0) can return 0 Hz for up to
            // ~500ms after engine.start(). Installing a tap during this window crashes with
            // "Input HW format is invalid" (AVAudioIONodeImpl.mm:1322).
            var hwReady = false
            for attempt in 1...10 {
                // FIX #1583: Use outputFormat (what startAudioCapture reads at line 583),
                // NOT inputFormat. inputFormat is the raw hardware format; outputFormat is
                // what the node produces downstream — they can differ. The readiness check
                // must match what startAudioCapture actually uses.
                let hwFormat = engine.inputNode.outputFormat(forBus: 0)
                if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 {
                    print("📞 FIX #1583: Input HW ready after \(attempt) attempts (sr=\(hwFormat.sampleRate), ch=\(hwFormat.channelCount))")
                    hwReady = true
                    break
                }
                print("📞 FIX #1583: Input HW not ready (attempt \(attempt)/10, sr=\(hwFormat.sampleRate), ch=\(hwFormat.channelCount)) — waiting 200ms...")
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }

            if !hwReady {
                print("📞 FIX #1541: Input HW format still invalid after 2s — microphone unavailable, audio capture disabled")
                // Don't crash — allow playback-only (can hear remote but can't send audio)
            } else {
                startAudioCapture()
            }
        } else {
            print("📞 FIX #1567: Microphone capture skipped — listen-only mode")
        }

        // Start call duration timer
        callDurationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.callStartTime else { return }
                self.callDuration = Date().timeIntervalSince(start)
            }
        }

        print("📞 FIX #1540: Audio session started — callId=\(callId.prefix(8))")
    }

    private func stopAudioSession() {
        audioSendTask?.cancel()
        audioSendTask = nil

        // FIX #1573: Only remove tap if we installed one — prevents crash on nil engine.
        // Also track hasTapInstalled to prevent orphaned taps that hold a reference to
        // the old engine and block future engines from getting mic access.
        if hasTapInstalled, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        print("📞 FIX #1540: Audio session stopped")
    }

    // MARK: - Audio Capture & Encoding

    private func startAudioCapture() {
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        var inputFormat = inputNode.outputFormat(forBus: 0)

        // FIX #1540: On iOS, inputNode.outputFormat can return 0 Hz / 0 channels if hardware
        // isn't ready yet. This causes "IsFormatSampleRateAndChannelCountValid(format)" crash
        // in CreateRecordingTap. Fall back to AVAudioSession's actual hardware format.
        #if os(iOS)
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            let hwSampleRate = AVAudioSession.sharedInstance().sampleRate
            let hwChannels = max(AVAudioSession.sharedInstance().inputNumberOfChannels, 1)
            print("📞 FIX #1540: inputNode format invalid (sr=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount)) — using session format (sr=\(hwSampleRate), ch=\(hwChannels))")
            if let fallback = AVAudioFormat(standardFormatWithSampleRate: hwSampleRate, channels: AVAudioChannelCount(hwChannels)) {
                inputFormat = fallback
            } else {
                print("📞 FIX #1540: Cannot create fallback audio format — aborting capture")
                return
            }
        }
        #endif

        // Install tap on input node — captures microphone audio
        // Convert to 16kHz mono PCM, then encode to compressed format
        guard let captureFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channels
        ) else {
            print("📞 FIX #1540: Failed to create capture audio format")
            return
        }

        // Use a converter if input format differs from our target
        let converter: AVAudioConverter?
        if inputFormat.sampleRate != sampleRate || inputFormat.channelCount != channels {
            converter = AVAudioConverter(from: inputFormat, to: captureFormat)
        } else {
            converter = nil
        }

        // FIX #1540: Capture constants locally — audio tap runs on audio thread, NOT MainActor
        let localSampleRate = sampleRate
        let localFrameDurationMs = frameDurationMs

        // Pass nil format to installTap — AVAudioEngine uses the node's native
        // output format. Passing a mismatched format causes silent/no tap delivery.
        hasTapInstalled = true  // FIX #1573: Track tap installation
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(localSampleRate * Double(localFrameDurationMs) / 1000.0), format: nil) { [weak self] buffer, time in
            guard let self = self else { return }

            // FIX #1573: Send every other frame (25fps instead of 50fps) to halve Tor bandwidth.
            // Combined with Int16 encoding: 640 bytes × 25fps = ~16KB/s vs original ~85KB/s.
            self.tapCallbackCount += 1
            if self.tapCallbackCount % 2 == 0 { return }  // Skip even frames

            // Convert to target format if needed
            let outputBuffer: AVAudioPCMBuffer
            if let conv = converter {
                guard let converted = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: AVAudioFrameCount(localSampleRate * Double(localFrameDurationMs) / 1000.0)) else { return }
                var error: NSError?
                // FIX #1573: Use inputConsumed flag — returning .haveData every time causes
                // the converter to process the same buffer twice → garbled/zero-length output.
                var inputConsumed = false
                conv.convert(to: converted, error: &error) { _, outStatus in
                    if inputConsumed {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    inputConsumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error != nil { return }
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }

            // FIX #1573: Convert Float32 → Int16 before sending. Halves bandwidth:
            // Float32: 320 samples × 4 bytes = 1280 bytes → base64 = 1708 bytes → ~85 KB/s
            // Int16:   320 samples × 2 bytes = 640 bytes  → base64 = 856 bytes  → ~43 KB/s
            // Tor hidden services have ~50-200 KB/s practical throughput — must stay under.
            guard let channelData = outputBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(outputBuffer.frameLength)
            var int16Samples = [Int16](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, channelData[i]))
                int16Samples[i] = Int16(clamped * Float(Int16.max))
            }
            let pcmData = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }
            let base64Audio = pcmData.base64EncodedString()

            let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

            // FIX #1585: Read MainActor state quickly, then send on background Task.
            // Old code: entire sendCallSignal awaited on MainActor → blocked UI + receive path
            // for 30-45s during Tor reconnects. Now: grab state on MainActor, fire-and-forget send.
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard !self.isMuted else { return }
                guard case .active(let callId) = self.callState,
                      let peer = self.remotePeerOnionAddress else { return }

                let seq = self.sendSequence
                self.sendSequence += 1

                let frame = CallAudioFrame(
                    callId: callId,
                    seq: seq,
                    ts: timestamp,
                    opus: base64Audio
                )

                guard let frameJSON = try? JSONEncoder().encode(frame),
                      let frameString = String(data: frameJSON, encoding: .utf8) else { return }

                // FIX #1585: Send on detached task — do NOT await on MainActor
                Task.detached {
                    await ChatManager.shared.sendCallSignal(
                        type: .callAudio,
                        content: frameString,
                        to: peer
                    )
                }
            }
        }
    }

    // MARK: - Jitter Buffer & Playback

    private func drainJitterBuffer() {
        guard let player = playerNode, let engine = audioEngine, engine.isRunning else { return }

        // FIX #1546: Ensure playerNode is actively playing — scheduleBuffer is silent otherwise
        if !player.isPlaying {
            player.play()
            print("📞 FIX #1546: playerNode restarted for audio playback")
        }

        // Play all consecutive frames starting from nextPlaybackSeq
        var framesPlayed = 0
        while let audioData = jitterBuffer[nextPlaybackSeq] {
            jitterBuffer.removeValue(forKey: nextPlaybackSeq)

            // FIX #1573: Decode Int16 PCM → Float32 for AVAudioPlayerNode.
            // Sender converts Float32 → Int16 to halve Tor bandwidth.
            let sampleCount = audioData.count / MemoryLayout<Int16>.size
            guard sampleCount > 0 else {
                nextPlaybackSeq += 1
                continue
            }

            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
                nextPlaybackSeq += 1
                continue
            }

            pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
            audioData.withUnsafeBytes { rawBuffer in
                guard let int16Ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                let floatPtr = pcmBuffer.floatChannelData![0]
                for i in 0..<sampleCount {
                    floatPtr[i] = Float(int16Ptr[i]) / Float(Int16.max)
                }
            }

            player.scheduleBuffer(pcmBuffer)
            framesPlayed += 1
            nextPlaybackSeq += 1
        }

        // FIX #1584: If no frames played but buffer has data, the leading packet was lost.
        // Skip forward to the lowest buffered sequence to prevent permanent deadlock.
        if framesPlayed == 0 && !jitterBuffer.isEmpty {
            if let minSeq = jitterBuffer.keys.min(), minSeq > nextPlaybackSeq {
                let skipped = minSeq - nextPlaybackSeq
                print("📞 FIX #1584: Skipping \(skipped) lost packets (seq \(nextPlaybackSeq)→\(minSeq)), buffer=\(jitterBuffer.count)")
                nextPlaybackSeq = minSeq
                // Retry drain now that nextPlaybackSeq points to a buffered frame
                drainJitterBuffer()
                return
            }
        }

        if framesPlayed > 0 {
            print("📞 FIX #1546: Played \(framesPlayed) audio frames, next seq=\(nextPlaybackSeq), buffer=\(jitterBuffer.count)")
        }

        // Cleanup old frames (more than 500ms behind)
        let oldThreshold = nextPlaybackSeq > 25 ? nextPlaybackSeq - 25 : 0
        jitterBuffer = jitterBuffer.filter { $0.key >= oldThreshold }
    }

    // MARK: - Ringtone Generation & Playback (FIX #1563)

    /// Start playing ringtone based on call direction
    /// - isIncoming: true = phone ringing (receiver), false = ringback tone (caller)
    private func startRingtone(isIncoming: Bool) {
        stopRingtone()

        #if os(iOS)
        // Set audio session for ringtone playback (before audio engine takes over)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("📞 FIX #1563: Audio session for ringtone failed: \(error)")
        }

        // Vibrate on incoming calls (every 2s)
        if isIncoming {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            vibrationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
        #endif

        let wavData = Self.generateRingtone(isIncoming: isIncoming)
        do {
            ringtonePlayer = try AVAudioPlayer(data: wavData)
            ringtonePlayer?.numberOfLoops = -1  // Loop forever
            ringtonePlayer?.volume = 0.7
            ringtonePlayer?.play()
            print("📞 FIX #1563: Ringtone started (incoming=\(isIncoming))")
        } catch {
            print("📞 FIX #1563: Ringtone playback failed: \(error)")
        }
    }

    /// Stop ringtone and vibration
    private func stopRingtone() {
        ringtonePlayer?.stop()
        ringtonePlayer = nil
        #if os(iOS)
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        // FIX #1576: Deactivate audio session after ringtone — allows clean switch
        // from .playback to .playAndRecord in beginAudioSession()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Generate ringtone as in-memory WAV data (no external sound files needed)
    /// Incoming: 800Hz+1000Hz double beep — beep(300ms), silence(150ms), beep(300ms), silence(3250ms)
    /// Outgoing: 440Hz+480Hz ringback — tone(2000ms), silence(4000ms)
    private static func generateRingtone(isIncoming: Bool) -> Data {
        let sampleRate = 44100
        let amplitude: Double = 6000  // 16-bit, moderate volume

        var samples = [Int16]()

        if isIncoming {
            // Double-beep pattern: beep-beep-pause (~4 seconds total)
            let segments: [(freqs: [Double], ms: Int)] = [
                ([800, 1000], 300),   // beep
                ([], 150),            // short gap
                ([800, 1000], 300),   // beep
                ([], 3250),           // long pause
            ]
            for seg in segments {
                let count = sampleRate * seg.ms / 1000
                for i in 0..<count {
                    if seg.freqs.isEmpty {
                        samples.append(0)
                    } else {
                        let t = Double(i) / Double(sampleRate)
                        var v: Double = 0
                        for f in seg.freqs { v += sin(2.0 * .pi * f * t) }
                        v /= Double(seg.freqs.count)
                        samples.append(Int16(v * amplitude))
                    }
                }
            }
        } else {
            // Ringback tone: standard North American (440+480Hz)
            let segments: [(freqs: [Double], ms: Int)] = [
                ([440, 480], 2000),   // ring
                ([], 4000),           // silence
            ]
            for seg in segments {
                let count = sampleRate * seg.ms / 1000
                for i in 0..<count {
                    if seg.freqs.isEmpty {
                        samples.append(0)
                    } else {
                        let t = Double(i) / Double(sampleRate)
                        var v: Double = 0
                        for f in seg.freqs { v += sin(2.0 * .pi * f * t) }
                        v /= Double(seg.freqs.count)
                        samples.append(Int16(v * amplitude))
                    }
                }
            }
        }

        // Build WAV file in memory
        let dataSize = UInt32(samples.count * 2)
        var wav = Data()
        wav.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
        appendLE(&wav, UInt32(36 + dataSize))
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"

        // fmt chunk
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
        appendLE(&wav, UInt32(16))                          // chunk size
        appendLE(&wav, UInt16(1))                           // PCM format
        appendLE(&wav, UInt16(1))                           // mono
        appendLE(&wav, UInt32(sampleRate))                  // sample rate
        appendLE(&wav, UInt32(sampleRate * 2))              // byte rate
        appendLE(&wav, UInt16(2))                           // block align
        appendLE(&wav, UInt16(16))                          // bits per sample

        // data chunk
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
        appendLE(&wav, dataSize)

        // PCM samples
        for sample in samples {
            appendLE(&wav, sample)
        }

        return wav
    }

    /// Append a value in little-endian byte order
    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }

    // MARK: - Helpers

    /// Format call duration for display (MM:SS)
    static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
