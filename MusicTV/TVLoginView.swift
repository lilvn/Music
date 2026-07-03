import SwiftUI

/// Sign-in for the TV: plain fields (the system shows the full-screen tvOS keyboard on focus).
struct TVLoginView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var error: String?

    private var canSubmit: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 30) {
            Text("Sign In to Jellyfin")
                .font(.title2).fontWeight(.bold)

            // Deliberately bare fields: on tvOS 26 the input-trait modifiers (textContentType /
            // autocapitalization / autocorrection) on these fields triggered an AttributeGraph cycle
            // and a DynamicContainer fatal on first layout — the app crashed ON the sign-in screen.
            VStack(spacing: 20) {
                TextField("Server address", text: $server)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            .frame(maxWidth: 800)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            Button {
                login()
            } label: {
                if isLoading { ProgressView() } else { Text("Sign In").frame(maxWidth: 300) }
            }
            .disabled(!canSubmit || isLoading)
        }
        .padding(60)
    }

    private func login() {
        isLoading = true
        error = nil
        Task {
            do {
                try await client.authenticate(server: server, username: username, password: password)
            } catch {
                if case APIError.httpError(401) = error {
                    self.error = "Incorrect username or password."
                } else {
                    self.error = "Couldn't reach the server. Check the address and your connection."
                }
            }
            isLoading = false
        }
    }
}

/// TV settings: the connected server, and sign out (clears this device's saved login).
struct TVSettingsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Address", value: client.serverURL)
                    LabeledContent("User", value: client.username)
                }
                Section {
                    Button("Sign Out", role: .destructive) {
                        TVVideoController.shared.exit(audio: player, resumeAudio: false)
                        player.stop()
                        client.signOut()
                        dismiss()
                    }
                }
                Section {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
