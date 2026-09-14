import SwiftUI

/// First run, and the whole of it: three numbered steps on one screen.
///
/// Copy the prompt, hand it to an agent, type back the six characters it answers with.
/// There is no address field, because there is nothing here a person could be expected to
/// know. The app finds the server on the local network, and the address it keeps afterwards
/// is the one the server names in its pairing reply.
struct PairingView: View {
    @State private var pairing = Pairing.shared
    @State private var discovery = ServerDiscovery()
    @State private var code = ""
    @State private var working = false
    @State private var copied = false
    @State private var failure: String?
    @FocusState private var codeFocused: Bool

    /// Same alphabet the server mints from: Crockford base32 without the look-alikes.
    private static let codeCharacters = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    intro
                    copyStep
                    handOffStep
                    codeStep
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { footer }
            .screenGround()
            .navigationTitle("Set Up Turntable")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .animation(Theme.spring, value: failure)
        .task {
            discovery.start()
            prefillFromLaunchEnvironment()
        }
        .onDisappear { discovery.stop() }
    }

    // MARK: Steps

    private var intro: some View {
        VStack(spacing: 8) {
            VinylMark(size: 54, spinning: true)
                .shadow(color: Theme.accent.opacity(0.18), radius: 22)
            Text("Your agent picks. This phone plays.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private var copyStep: some View {
        StepCard(number: 1, title: "Copy the setup prompt") {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(Config.setupPrompt)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 104)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.86),
                                             .init(color: .black.opacity(0), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .background(.thinMaterial,
                            in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 0.5)
                )
                .accessibilityLabel("Setup prompt")

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = Config.setupPrompt
                        Haptics.tap()
                        withAnimation(Theme.springy) { copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy Prompt",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    ShareLink(item: Config.setupPrompt) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Share setup prompt")
                }
            }
        }
    }

    private var handOffStep: some View {
        StepCard(number: 2, title: "Paste it to your coding agent") {
            Text("Any agent with a shell on the machine that runs the server. It does the rest.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codeStep: some View {
        StepCard(number: 3, title: "Enter the code it sends back") {
            VStack(alignment: .leading, spacing: 12) {
                CodeField(code: $code, focused: $codeFocused)
                    .onChange(of: code) { old, new in
                        code = Self.clean(new)
                        if code.count > old.count { Haptics.selection() }
                        if code.count == 6 { pair() }
                    }
                Label {
                    Text(discoveryWord)
                } icon: {
                    Image(systemName: discoverySymbol)
                        .imageScale(.small)
                }
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Footer

    /// The one prominent button on the screen, and the only place a failure is ever shown.
    private var footer: some View {
        VStack(spacing: 12) {
            if let failure {
                FailureNote(text: failure)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            PrimaryButton(title: "Pair This Phone", loading: working, enabled: code.count == 6) {
                pair()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.bar)
    }

    /// Discovery is reported in words, never as a spinner that means nothing. Three states,
    /// three glyph shapes, so it reads with the colour off.
    private var discoveryWord: String {
        if let first = discovery.candidates.first, discovery.candidates.count == 1 {
            return "Server found at \(first.host() ?? first.absoluteString)"
        }
        if discovery.candidates.count > 1 {
            return "\(discovery.candidates.count) servers found on this Wi-Fi"
        }
        return "Looking for the server on this Wi-Fi"
    }

    private var discoverySymbol: String {
        discovery.candidates.isEmpty ? "wifi" : "checkmark.circle"
    }

    // MARK: Logic

    private static func clean(_ raw: String) -> String {
        String(raw.uppercased().filter(codeCharacters.contains).prefix(6))
    }

    private func pair() {
        guard !working, code.count == 6 else { return }
        codeFocused = false
        working = true
        failure = nil
        Task {
            do {
                let found = await discovery.addresses(waitingUpTo: .seconds(6))
                try await pairing.pair(code: code, candidates: found)
                Haptics.notify(.success)
            } catch {
                Haptics.notify(.error)
                report(error)
                codeFocused = true
            }
            working = false
        }
    }

    /// TURNTABLE_PAIR_CODE types the six characters, the same headless-screenshot hook as
    /// TURNTABLE_TAB, because `simctl` cannot tap. It stands in for the keyboard and for
    /// nothing else: the code is redeemed against whatever discovery found, through the
    /// same call the button makes. TURNTABLE_PAIR_ADDRESS additionally stands in for
    /// discovery, for the case where the two machines cannot see each other.
    private func prefillFromLaunchEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard let seedCode = env["TURNTABLE_PAIR_CODE"] else { return }
        code = Self.clean(seedCode)
        guard code.count == 6 else { return }

        if let address = env["TURNTABLE_PAIR_ADDRESS"], let base = Pairing.normalize(address) {
            working = true
            Task {
                do { try await pairing.pair(code: code, candidates: [base]) } catch { report(error) }
                working = false
            }
        }
        // A full code pairs itself: the field's own onChange calls pair(), which waits for
        // discovery the same way it does when a person finishes typing.
    }

    private func report(_ error: Error) {
        failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        code = ""
    }
}

// MARK: - Pieces

/// One numbered step: a counter, a title, and whatever the step asks for underneath.
/// The number is a badge rather than a "STEP 1 OF 3" caption, because with all three on
/// screen at once the position is the progress.
private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.footnote.weight(.bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
                    .background(Theme.accent, in: Circle())
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardInset)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title)")
    }
}

/// Six glyph cells over one hidden field. Typing fills the cells; the live cell carries an
/// ember outline and a caret, so the focus point reads without relying on colour.
private struct CodeField: View {
    @Binding var code: String
    @FocusState.Binding var focused: Bool
    @State private var caretOn = true

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .focused($focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("Pairing code")

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    cell(index)
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(520))
                caretOn.toggle()
            }
        }
    }

    private func cell(_ index: Int) -> some View {
        let characters = Array(code)
        let filled = index < characters.count
        let live = focused && index == characters.count
        let radius = Theme.innerRadius
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(filled ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(live ? Theme.accent : Theme.separator, lineWidth: live ? 1.6 : 0.5)

            if filled {
                Text(String(characters[index]))
                    .font(.title2.weight(.semibold).monospaced())
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else if live {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2, height: 24)
                    .opacity(caretOn ? 1 : 0)
            }
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .animation(Theme.springy, value: filled)
        .animation(Theme.quick, value: live)
    }
}
