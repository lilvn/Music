import SwiftUI

/// First-launch sign-in: server + username + password. A plain native Form — no custom styling, glass or
/// gradient (those re-composited on every keystroke and made typing janky). On success the credentials
/// persist and the app switches to the library.
struct LoginView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    private var canSubmit: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        // A native Form — the most efficient way to host a few text fields. It handles keyboard
        // avoidance itself and adds no custom rendering, so typing has nothing extra to redraw.
        Form {
            Section {
                TextField("Server address", text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .focused($focus, equals: .server)
                    .onSubmit { focus = .username }
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit { if canSubmit { login() } }
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }

            Section {
                Button(action: login) {
                    if isLoading { ProgressView() } else { Text("Sign In") }
                }
                .disabled(!canSubmit || isLoading)
            }
        }
        .disabled(isLoading)
    }

    private func login() {
        focus = nil               // drop the keyboard immediately so the spinner is visible
        isLoading = true
        error = nil
        Task {
            do {
                try await client.authenticate(server: server, username: username, password: password)
            } catch {
                // Tell the user which knob to turn rather than a catch-all — fewer blind retries.
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

/// Server management — view the connected server and sign out.
struct SettingsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @Environment(AudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var storageText = "—"

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Address", value: client.serverURL)
                    LabeledContent("User", value: client.username)
                }

                Section {
                    Toggle("Download over Wi-Fi", isOn: Binding(
                        get: { store.offlineEnabled },
                        set: { store.offlineEnabled = $0 }))
                    LabeledContent("Downloaded", value: "\(store.downloadedIds.count) tracks")
                    LabeledContent("Storage", value: storageText)
                    Button("Clear Downloads", role: .destructive) {
                        store.clearAll()
                        storageText = byteText(0)
                    }
                    .disabled(store.downloadedIds.isEmpty)
                } header: {
                    Text("Offline")
                } footer: {
                    Text("Liked Songs, Most Played, and your playlists download automatically over Wi-Fi so they keep playing without a connection.")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        player.stop()
                        client.signOut()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { storageText = byteText(store.storageBytes()) }
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
