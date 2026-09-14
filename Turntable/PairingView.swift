import SwiftUI

/// First run, and the whole of it: three numbered steps on one screen.
///
/// Copy the prompt, hand it to an agent, enter the one code it answers with. There is no
/// address field and no second path, because there is nothing here a person could be
/// expected to know. Which code they get is the server's decision, not theirs: six
/// characters when it is sitting on this Wi-Fi and the app can find it, a longer `TT1-`
/// code carrying its own address when it is not. Both go in the same field.
///
/// Either way the address the phone keeps afterwards is the one the server names in its
/// pairing reply, never the one in the code.
struct PairingView: View {
    @State private var pairing = Pairing.shared
    @State private var discovery = ServerDiscovery()
    @State private var code = ""
    @State private var working = false
    @State private var copied = false
    @State private var failure: String?
    @FocusState private var codeFocused: Bool

    private static let codeStepID = "code-step"

    private var reading: PairingCode.Reading { PairingCode.read(code) }

    private var isLongCode: Bool { PairingCode.isLong(code) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 12) {
                        intro
                        copyStep
                        handOffStep
                        codeStep(scroller)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom) { footer }
            }
            .screenGround()
            .navigationTitle("Set Up Turntable")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .animation(Theme.spring, value: failure)
        .animation(Theme.quick, value: isLongCode)
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
            Text("Any agent with a shell. It works out where to run the server and sends back one code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeStep(_ scroller: ScrollViewProxy) -> some View {
        StepCard(number: 3, title: "Enter the code it sends back") {
            VStack(alignment: .leading, spacing: 12) {
                CodeField(code: $code, focused: $codeFocused)
                    .onChange(of: code) { old, new in
                        code = Self.clean(new)
                        if code.count > old.count, !isLongCode { Haptics.selection() }
                        // A long code makes this card tall enough to push its own status
                        // line under the action bar, and that line is the one saying where
                        // the code points. Bring the step back into view when it grows.
                        if isLongCode {
                            // One layout pass later: the card has not grown yet at the
                            // moment the text changes, and scrolling to where it used to
                            // end leaves the line under the bar.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(60))
                                withAnimation(Theme.spring) {
                                    scroller.scrollTo(Self.codeStepID, anchor: .bottom)
                                }
                            }
                        }
                        if case .ready = reading { pair() }
                    }

                // Pasting is the system's job and it already does it: long-press the field
                // and the edit menu offers Paste, for six characters or for sixty. A
                // PasteButton of our own would be a second filled capsule next to the one
                // prominent button on the screen, and it only renders at all in the system's
                // prominent style, so it is not here.
                Label {
                    Text(status.words)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: status.symbol)
                        .imageScale(.small)
                }
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(Self.codeStepID)
    }

    // MARK: Footer

    /// The one prominent button on the screen, and the only place a failure is ever shown.
    private var footer: some View {
        VStack(spacing: 12) {
            if let failure {
                FailureNote(text: failure)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            PrimaryButton(title: "Pair This Phone", loading: working, enabled: reading.isReady) {
                pair()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.bar)
    }

    /// One line under the field, about the code in the field. Never a spinner that means
    /// nothing, and every state has its own glyph shape so it reads with the colour off.
    /// Failures from an actual pairing attempt belong to the footer, not here.
    private var status: (symbol: String, words: String) {
        switch reading {
        case .ready(.remote(let url, _)):
            ("globe", "This code points at \(url.host() ?? url.absoluteString)")
        case .rejected(let failure):
            ("exclamationmark.triangle", failure.errorDescription ?? "That code cannot be used.")
        case .incomplete where isLongCode:
            ("ellipsis", "That code is cut short. Paste the whole thing.")
        default:
            (discovery.candidates.isEmpty ? "wifi" : "checkmark.circle", discoveryWord)
        }
    }

    /// Discovery is reported in words too. It only matters for a six character code, which
    /// is why it is the default line and not the only one.
    private var discoveryWord: String {
        if let first = discovery.candidates.first, discovery.candidates.count == 1 {
            return "Server found at \(first.host() ?? first.absoluteString)"
        }
        if discovery.candidates.count > 1 {
            return "\(discovery.candidates.count) servers found on this Wi-Fi"
        }
        return "Looking for the server on this Wi-Fi"
    }

    // MARK: Logic

    /// What the field is allowed to hold. A six character code is folded to the server's
    /// uppercase alphabet as it is typed; a `TT1-` code is base64url, where case carries
    /// meaning, so it is kept exactly as pasted minus whitespace.
    private static func clean(_ raw: String) -> String {
        let text = String(raw.filter { !$0.isWhitespace })
        if PairingCode.isLong(text) {
            return String(text.prefix(PairingCode.maxLength))
        }
        // "T", "TT", "TT1": someone typing a long code out by hand, mid-prefix. Without
        // this the "1" is filtered away as not-in-alphabet and the prefix never forms.
        if !text.isEmpty, PairingCode.prefix.hasPrefix(text.uppercased()) {
            return text.uppercased()
        }
        return String(text.uppercased().filter(PairingCode.alphabet.contains).prefix(PairingCode.lanLength))
    }

    private func pair() {
        guard !working, case .ready(let parsed) = reading else { return }
        codeFocused = false
        working = true
        failure = nil
        Task {
            do {
                switch parsed {
                case .remote:
                    // The code names the one address worth trying. Discovery has nothing to
                    // add: a server in a data centre does not announce itself on this Wi-Fi.
                    try await pairing.pair(parsed)
                case .lan:
                    try await pairing.pair(parsed, candidates: await discovery.addresses(waitingUpTo: .seconds(6)))
                }
                Haptics.notify(.success)
            } catch {
                Haptics.notify(.error)
                report(error)
                codeFocused = true
            }
            working = false
        }
    }

    /// TURNTABLE_PAIR_CODE fills the field, the same headless-screenshot hook as
    /// TURNTABLE_TAB, because `simctl` cannot tap or paste. It stands in for the keyboard
    /// and for nothing else: either shape of code goes in here and takes exactly the route
    /// it takes when a person enters it, because the field's own onChange calls pair().
    private func prefillFromLaunchEnvironment() {
        guard let seed = ProcessInfo.processInfo.environment["TURNTABLE_PAIR_CODE"] else { return }
        DebugLog.shared.add("pair", "seeding code from launch environment")
        code = Self.clean(seed)
    }

    /// A failure about the code empties the field, because the next step is a new code. A
    /// failure about the network does not: the code is still good, and making someone paste
    /// ninety characters again to retry a connection would be a punishment for their Wi-Fi.
    private func report(_ error: Error) {
        failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        switch error as? Pairing.Failure {
        case .cannotReach, .noInternet, .noServerFound: break
        default: code = ""
        }
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

/// One field, two faces. Six glyph cells for a six character code, where the live cell
/// carries an ember outline and a caret so the focus point reads without relying on colour.
/// One wrapped monospaced block for a `TT1-` code, which is pasted rather than typed and is
/// far too long for cells. Both sit over the same hidden text field, so there is one place
/// a code goes in no matter which one the agent sent.
private struct CodeField: View {
    @Binding var code: String
    @FocusState.Binding var focused: Bool
    @State private var caretOn = true

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.asciiCapable)
                // The six character codes are folded to uppercase as they are typed. A
                // long code is base64url, where case is data, so the keyboard must not
                // touch it.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .focused($focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("Pairing code")

            Group {
                if PairingCode.isLong(code) {
                    longCode
                } else {
                    HStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { index in
                            cell(index)
                        }
                    }
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

    /// The whole code, wrapped over as many as four lines. This is the one chance anybody
    /// has to see that what landed in the field is what their agent sent, so it is shown
    /// rather than summarised, and anything longer loses its middle rather than its tail.
    private var longCode: some View {
        Text(code)
            .font(.footnote.monospaced())
            .lineLimit(4, reservesSpace: false)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .frame(minHeight: 56)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Theme.separator,
                                  lineWidth: focused ? 1.6 : 0.5)
            )
            .animation(Theme.quick, value: focused)
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
