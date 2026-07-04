import SwiftUI

/// Mac login — the same minimal Jellyfin connect card as the other platforms.
struct MacLoginView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Music2.0")
                .font(.title).fontWeight(.bold)
            Text("Connect to your Jellyfin server")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 10) {
                TextField("Server (https://…)", text: $server)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 320)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Button {
                connect()
            } label: {
                if busy { ProgressView().controlSize(.small) }
                else { Text("Connect").padding(.horizontal, 22).padding(.vertical, 6) }
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || server.isEmpty || username.isEmpty)
        }
        .frame(minWidth: 520, minHeight: 460)
    }

    private func connect() {
        busy = true; error = nil
        Task {
            do {
                try await client.authenticate(server: server, username: username, password: password)
            } catch {
                self.error = "Couldn't connect — check the address and login."
            }
            busy = false
        }
    }
}
