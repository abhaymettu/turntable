import SwiftUI

/// First run. Nothing works until the phone knows which server to follow, so this is the
/// whole screen rather than a setting buried in a tab. Two fields, one button, and on a
/// failure the exact reason instead of "something went wrong".
struct PairingView: View {
    @State private var pairing = Pairing.shared
    @State private var address = ""
    @State private var code = ""
    @State private var working = false
    @State private var failure: String?
    @FocusState private var focus: Field?

    private enum Field { case address, code }

    /// Same alphabet the server mints from: Crockford base32 without the look-alikes.
    private static let codeCharacters = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Turntable plays what an agent picks. The agent runs a small server, and this phone follows it.")
                    Text("Ask your agent to start the server and run `python3 server.py --pair`. It prints an address and a six character code. Both go here.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                Section("Server address") {
                    TextField("http://192.168.1.20:8787", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.next)
                        .focused($focus, equals: .address)
                        .onSubmit { focus = .code }
                }

                Section {
                    TextField("ABC234", text: $code)
                        .font(.title3.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focus, equals: .code)
                        .onChange(of: code) { _, new in code = Self.clean(new) }
                        .onSubmit { pair() }
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Codes last 15 minutes and work once.")
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }

                Section {
                    Button {
                        pair()
                    } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text("Pair") }
                            Spacer()
                        }
                    }
                    .disabled(working || code.count != 6 || address.isEmpty)
                }
            }
            .navigationTitle("Turntable")
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { focus = .address }
    }

    private static func clean(_ raw: String) -> String {
        String(raw.uppercased().filter(codeCharacters.contains).prefix(6))
    }

    private func pair() {
        guard !working, code.count == 6 else { return }
        focus = nil
        working = true
        failure = nil
        Task {
            do {
                try await pairing.pair(address: address, code: code)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                code = ""
            }
            working = false
        }
    }
}
