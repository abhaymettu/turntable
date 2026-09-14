import SwiftUI

/// First run. Nothing works until the phone knows which server to follow, so this is the
/// whole app: an Apple-style welcome, then one thing asked at a time, and on a failure the
/// exact reason instead of "something went wrong".
struct PairingView: View {
    private enum Step: Int { case welcome, address, code }

    @State private var pairing = Pairing.shared
    @State private var step: Step = .welcome
    @State private var address = ""
    @State private var code = ""
    @State private var working = false
    @State private var failure: String?
    @FocusState private var addressFocused: Bool
    @FocusState private var codeFocused: Bool

    /// Same alphabet the server mints from: Crockford base32 without the look-alikes.
    private static let codeCharacters = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case .welcome: welcome
                    case .address: addressStep
                    case .code: codeStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .offset(x: 40).combined(with: .opacity),
                    removal: .offset(x: -40).combined(with: .opacity)
                ))
                footer
            }
            .screenGround()
            .navigationTitle(step == .welcome ? "" : "Pair a Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            failure = nil
                            withAnimation(Theme.spring) { step = step == .code ? .address : .welcome }
                        } label: { Label("Back", systemImage: "chevron.left") }
                    }
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .animation(Theme.spring, value: step)
        .animation(Theme.spring, value: failure)
        .task { prefillFromLaunchEnvironment() }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            if let failure {
                FailureNote(text: failure)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            switch step {
            case .welcome:
                PrimaryButton(title: "Set Up Turntable") {
                    withAnimation(Theme.spring) { step = .address }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { addressFocused = true }
                }
            case .address:
                PrimaryButton(title: "Continue", enabled: Pairing.normalize(address) != nil) {
                    failure = nil
                    addressFocused = false
                    withAnimation(Theme.spring) { step = .code }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { codeFocused = true }
                }
            case .code:
                PrimaryButton(title: "Pair This Phone", loading: working, enabled: code.count == 6) {
                    pair()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VinylMark(size: 140, spinning: true)
                .shadow(color: Theme.accent.opacity(0.18), radius: 44)
                .padding(.bottom, 30)

            Text("Turntable")
                .font(.largeTitle.weight(.bold))
                .minimumScaleFactor(0.8)
            Text("Your agent picks. This phone plays.")
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            Spacer(minLength: 24)

            // The Apple welcome-screen pattern: a short list of what the app does, each line
            // a symbol and a sentence, sitting on one surface above the button.
            VStack(spacing: 0) {
                PointRow(symbol: "antenna.radiowaves.left.and.right",
                         text: "Your agent steers what plays, over the air")
                Divider().overlay(Theme.separator)
                PointRow(symbol: "music.note", text: "Plays through Apple Music on this phone")
                Divider().overlay(Theme.separator)
                PointRow(symbol: "waveform", text: "Podcasts and video live here too")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .card(18)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 4)
    }

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(
                step: 1,
                title: "Where is the server?",
                detail: "Ask your agent to start it and run server.py --pair. It prints an address and a six character code."
            )

            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("", text: $address,
                          prompt: Text("turntable.example.com").foregroundStyle(.tertiary))
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.next)
                    .focused($addressFocused)
                    .accessibilityLabel("Server address")
                    .onSubmit {
                        guard Pairing.normalize(address) != nil else { return }
                        withAnimation(Theme.spring) { step = .code }
                        codeFocused = true
                    }
                if !address.isEmpty {
                    Button { address = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("Clear address")
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .card(14, material: .thinMaterial)
            .padding(.top, 24)

            Label("http:// is added for you. https works too.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Theme.quick, value: address.isEmpty)
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(
                step: 2,
                title: "Enter the pairing code",
                detail: "Six characters from the server. Codes last 15 minutes and work once."
            )

            CodeField(code: $code, focused: $codeFocused)
                .padding(.top, 26)
                .onChange(of: code) { _, new in
                    code = Self.clean(new)
                    if code.count == 6 { pair() }
                }

            Label {
                Text(Pairing.normalize(address)?.host() ?? address)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "server.rack").imageScale(.small)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
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
                try await pairing.pair(address: address, code: code)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                code = ""
                codeFocused = true
            }
            working = false
        }
    }

    /// TURNTABLE_PAIR_ADDRESS and TURNTABLE_PAIR_CODE prefill the two steps and open the one
    /// they reach, the same headless-screenshot hook as TURNTABLE_TAB. A full six character
    /// code pairs for real against that address; nothing here bypasses the server.
    private func prefillFromLaunchEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard let prefilled = env["TURNTABLE_PAIR_ADDRESS"], !prefilled.isEmpty else { return }
        address = prefilled
        guard let seedCode = env["TURNTABLE_PAIR_CODE"] else {
            step = .address
            return
        }
        step = .code
        code = Self.clean(seedCode)
        if code.count == 6 { pair() }
    }
}

// MARK: - Pieces

private struct StepTitle: View {
    let step: Int
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // In the content, not the toolbar: a bare toolbar string gets the system's
            // glass capsule and then reads as a button nobody can press.
            Text("STEP \(step) OF 2")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Step \(step) of 2")
            Text(title).font(.title.weight(.bold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PointRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.14), in: Circle())
        }
        .labelStyle(.titleAndIcon)
        .padding(.vertical, 10)
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
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(filled ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        .frame(height: 58)
        .frame(maxWidth: .infinity)
        .animation(Theme.springy, value: filled)
        .animation(Theme.quick, value: live)
    }
}
