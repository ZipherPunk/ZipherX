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
// Bandwidth: ~7.5 KB/s per direction (50 frames/s × ~150 bytes/frame)
// Latency: 400-800ms over Tor (3 hops), usable for conversation with jitter buffer

import Foundation
import AVFoundation
import Combine

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

    // FIX #1552: Cooldown to prevent rapid-fire call attempts when peer is offline
    private var lastCallEndTime: Date?
    private let callCooldownSeconds: TimeInterval = 2.0

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

        // Start 30s ring timeout
        ringTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
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

        // Auto-reject after 30s if not answered
        ringTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
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
        #endif

        callState = .active(callId: callId)
        callStartTime = Date()

        // Configure audio session
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
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

        // Output format for playback
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channels
        ) else {
            print("📞 FIX #1540: Failed to create output audio format")
            await endCall(reason: "audio_error")
            return
        }

        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

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

        // FIX #1541: Wait for input hardware to initialize before installing tap.
        // On iOS, engine.inputNode.inputFormat(forBus: 0) can return 0 Hz for up to
        // ~500ms after engine.start(). Installing a tap during this window crashes with
        // "Input HW format is invalid" (AVAudioIONodeImpl.mm:1322).
        var hwReady = false
        for attempt in 1...10 {
            let hwFormat = engine.inputNode.inputFormat(forBus: 0)
            if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 {
                print("📞 FIX #1541: Input HW ready after \(attempt) attempts (sr=\(hwFormat.sampleRate), ch=\(hwFormat.channelCount))")
                hwReady = true
                break
            }
            print("📞 FIX #1541: Input HW not ready (attempt \(attempt)/10, sr=\(hwFormat.sampleRate), ch=\(hwFormat.channelCount)) — waiting 200ms...")
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        if !hwReady {
            print("📞 FIX #1541: Input HW format still invalid after 2s — microphone unavailable, audio capture disabled")
            // Don't crash — allow playback-only (can hear remote but can't send audio)
        } else {
            startAudioCapture()
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

        audioEngine?.inputNode.removeTap(onBus: 0)
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

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(localSampleRate * Double(localFrameDurationMs) / 1000.0), format: inputFormat) { [weak self] buffer, time in
            guard self != nil else { return }

            // Convert to target format if needed
            let outputBuffer: AVAudioPCMBuffer
            if let conv = converter {
                guard let converted = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: AVAudioFrameCount(localSampleRate * Double(localFrameDurationMs) / 1000.0)) else { return }
                var error: NSError?
                conv.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error != nil { return }
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }

            // Encode PCM to base64 (lightweight encoding — actual Opus would be better but needs C lib)
            // Using raw PCM base64 for Phase 1 — ~3.2KB per 20ms frame at 16kHz mono 16-bit
            // TODO: Phase 2 — integrate Opus via SPM for ~80 bytes per frame (40x compression)
            guard let channelData = outputBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(outputBuffer.frameLength)
            let pcmData = Data(bytes: channelData, count: frameCount * MemoryLayout<Float>.size)
            let base64Audio = pcmData.base64EncodedString()

            let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

            // FIX #1540: All @MainActor property access inside Task block (audio thread safety)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Check mute and call state on MainActor
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

                await ChatManager.shared.sendCallSignal(
                    type: .callAudio,
                    content: frameString,
                    to: peer
                )
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

            // Decode base64 PCM data back to audio buffer
            let floatCount = audioData.count / MemoryLayout<Float>.size
            guard floatCount > 0 else {
                nextPlaybackSeq += 1
                continue
            }

            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(floatCount)) else {
                nextPlaybackSeq += 1
                continue
            }

            pcmBuffer.frameLength = AVAudioFrameCount(floatCount)
            audioData.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress {
                    memcpy(pcmBuffer.floatChannelData![0], baseAddress, audioData.count)
                }
            }

            // FIX #1546: Set volume on buffer to ensure audibility
            player.scheduleBuffer(pcmBuffer)
            framesPlayed += 1
            nextPlaybackSeq += 1
        }

        if framesPlayed > 0 {
            print("📞 FIX #1546: Played \(framesPlayed) audio frames, next seq=\(nextPlaybackSeq), buffer=\(jitterBuffer.count)")
        }

        // Cleanup old frames (more than 500ms behind)
        let oldThreshold = nextPlaybackSeq > 25 ? nextPlaybackSeq - 25 : 0
        jitterBuffer = jitterBuffer.filter { $0.key >= oldThreshold }
    }

    // MARK: - Helpers

    /// Format call duration for display (MM:SS)
    static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
