import SwiftUI

/// Floating "Transfer to this device" pill — appears in the TOP-RIGHT corner of any device that isn't
/// the one currently playing, and pulls the remote session (queue + position) onto this device.
struct TransferButton: View {
    @Environment(Player.self) private var player
    private var hub: SessionHub { SessionHub.shared }

    var body: some View {
        if let remote = hub.remote, !player.isPlaying {
            Button {
                hub.transferHere()
            } label: {
                HStack(spacing: 8) {
                    if hub.transferring {
                        ProgressView()
                    } else {
                        Image(systemName: "airplayaudio")
                    }
                    Text("Transfer Here")
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
#if os(iOS)
            .buttonStyle(.plain)
#else
            .buttonStyle(.borderless)
#endif
            .disabled(hub.transferring)
            .accessibilityLabel("Transfer playback from \(remote.deviceName) to this device")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

#if os(iOS)
/// Mini-bar mirror of a REMOTE session — shown in the bottom accessory when nothing is loaded locally
/// but another device of this account is playing. The controls drive the remote device.
struct RemoteMiniBar: View {
    @Environment(JellyfinClient.self) private var client
    private var hub: SessionHub { SessionHub.shared }

    var body: some View {
        if let remote = hub.remote {
            HStack(spacing: 10) {
                LibraryImage(url: client.artworkURL(for: remote.item, size: 160), maxPixel: 160) {
                    Color(.systemGray5)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(remote.item.name)
                        .font(.subheadline).fontWeight(.medium).lineLimit(1)
                    Text("Playing on \(remote.deviceName)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer(minLength: 6)

                Button { hub.previousRemote() } label: {
                    Image(systemName: "backward.fill").font(.body)
                }
                Button { hub.playPauseRemote() } label: {
                    Image(systemName: remote.isPaused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                Button { hub.nextRemote() } label: {
                    Image(systemName: "forward.fill").font(.body)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
    }
}
#endif
