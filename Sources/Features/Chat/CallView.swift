#if ENABLE_VOICE_CALLS
// CallView.swift
// ZipherX
//
// FIX #1540: Voice call UI — full-screen overlay for active/incoming/outgoing calls.
// Shows call timer, mute/speaker/hangup buttons, and incoming call accept/decline.

import SwiftUI

struct CallView: View {
    @ObservedObject var callManager = VoiceCallManager.shared
    @ObservedObject var chatManager = ChatManager.shared
    let contactName: String
    let onionAddress: String

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                gradient: Gradient(colors: [Color.black, Color(white: 0.1)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                // Contact avatar/icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 120, height: 120)

                    Image(systemName: "person.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                }

                // Contact name
                Text(contactName)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                // Call status
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(.gray)

                // Call duration (when active)
                if case .active = callManager.callState {
                    Text(VoiceCallManager.formatDuration(callManager.callDuration))
                        .font(.system(.title2, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }

                // Pulsing ring animation for ringing/offering
                if isRinging {
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                                .opacity(0.6)
                                .scaleEffect(isRinging ? 1.5 : 1.0)
                                .animation(
                                    .easeInOut(duration: 0.6)
                                    .repeatForever()
                                    .delay(Double(i) * 0.2),
                                    value: isRinging
                                )
                        }
                    }
                }

                Spacer()

                // Controls
                if case .ringing = callManager.callState {
                    // Incoming call — accept/decline
                    incomingCallControls
                } else if case .active = callManager.callState {
                    // Active call — mute/speaker/hangup
                    activeCallControls
                } else if case .offering = callManager.callState {
                    // Outgoing call — cancel
                    outgoingCallControls
                }

                Spacer()
                    .frame(height: 50)
            }
        }
    }

    // MARK: - Status Text

    private var statusText: String {
        switch callManager.callState {
        case .idle:
            return ""
        case .offering:
            return "Calling..."
        case .ringing:
            return "Incoming call"
        case .active:
            return "Encrypted call"
        case .ending:
            return "Ending call..."
        }
    }

    private var isRinging: Bool {
        switch callManager.callState {
        case .offering, .ringing:
            return true
        default:
            return false
        }
    }

    // MARK: - Incoming Call Controls

    private var incomingCallControls: some View {
        HStack(spacing: 60) {
            // Decline
            Button {
                Task {
                    await callManager.declineCall()
                }
            } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 64, height: 64)
                        Image(systemName: "phone.down.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    Text("Decline")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            // Accept
            Button {
                Task {
                    await callManager.acceptCall()
                }
            } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 64, height: 64)
                        Image(systemName: "phone.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    Text("Accept")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: - Active Call Controls

    private var activeCallControls: some View {
        HStack(spacing: 40) {
            // Mute
            Button {
                callManager.toggleMute()
            } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(callManager.isMuted ? Color.white : Color.white.opacity(0.2))
                            .frame(width: 56, height: 56)
                        Image(systemName: callManager.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title3)
                            .foregroundColor(callManager.isMuted ? .black : .white)
                    }
                    Text("Mute")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            // Speaker
            Button {
                callManager.toggleSpeaker()
            } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(callManager.isSpeakerOn ? Color.white : Color.white.opacity(0.2))
                            .frame(width: 56, height: 56)
                        Image(systemName: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill")
                            .font(.title3)
                            .foregroundColor(callManager.isSpeakerOn ? .black : .white)
                    }
                    Text("Speaker")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            // Hang up
            Button {
                Task {
                    await callManager.endCall()
                }
            } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 56, height: 56)
                        Image(systemName: "phone.down.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                    }
                    Text("End")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: - Outgoing Call Controls

    private var outgoingCallControls: some View {
        Button {
            Task {
                await callManager.endCall(reason: "cancelled")
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 64, height: 64)
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                Text("Cancel")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}
#endif // ENABLE_VOICE_CALLS
