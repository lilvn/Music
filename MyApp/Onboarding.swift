import SwiftUI

/// First-launch sign-in: enter a Jellyfin server + username + password. On success the credentials
/// persist and the app switches to the library. Nothing is baked into the app.
struct LoginView: View {
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
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "opticaldisc.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.primary)
                Text("Music").font(.largeTitle).fontWeight(.bold)
                Text("Connect to your Jellyfin server")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                TextField("Server (music.example.com)", text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)

            if let error {
                Text(error)
                    .font(.footnote).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button(action: login) {
                Group {
                    if isLoading { ProgressView().tint(Color(.systemBackground)) }
                    else { Text("Sign In").fontWeight(.semibold) }
                }
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(canSubmit ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color(.systemGray3)),
                            in: .capsule)
                .foregroundStyle(Color(.systemBackground))
            }
            .disabled(!canSubmit || isLoading)
            .padding(.horizontal)

            Spacer()
            Spacer()
        }
        .padding()
    }

    private func login() {
        isLoading = true
        error = nil
        Task {
            do {
                try await client.authenticate(server: server, username: username, password: password)
            } catch {
                self.error = "Couldn't sign in. Check the server address and your credentials."
            }
            isLoading = false
        }
    }
}

/// Server management — view the connected server and sign out.
struct SettingsView: View {
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
        }
    }
}
