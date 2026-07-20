import Cocoa
import ClaudeAPI

/// Manual sign-in for SSO setups the embedded login window can't complete —
/// e.g. an org that mandates a passkey/YubiKey in managed Chrome, which this
/// ad-hoc-signed app's WKWebView (no browser entitlement, not the managed
/// browser) can't satisfy. The user signs in with their real managed browser,
/// copies the Claude web session cookie (DevTools → Application → Cookies →
/// the Claude site → the session cookie), and pastes its value here. `onSubmit`
/// installs it into the widget's shared cookie store and reports back whether
/// the resulting session actually authenticates.
final class SessionKeyWindowController: NSWindowController, NSTextFieldDelegate {

    /// (pastedValue, done) → done(true) if the installed cookie authenticated.
    private let onSubmit: (String, @escaping (Bool) -> Void) -> Void

    private var field: NSTextField!
    private var statusLabel: NSTextField!
    private var signInButton: NSButton!

    init(onSubmit: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        self.onSubmit = onSubmit
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in with session cookie"
        super.init(window: window)
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let intro = NSTextField(wrappingLabelWithString:
            "Sign in to Claude in your managed browser (Chrome), then open " +
            "DevTools → Application → Cookies → https://\(ClaudeWebURLs.host) and copy the " +
            "value of the “\(ClaudeWebURLs.sessionCookieName)” cookie. Paste it below.")
        intro.font = .systemFont(ofSize: 12)

        let fieldLabel = NSTextField(labelWithString: ClaudeWebURLs.sessionCookieName)
        fieldLabel.font = .systemFont(ofSize: 11, weight: .medium)

        field = NSTextField()
        field.placeholderString = "sk-ant-sid01-…"
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail

        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        signInButton = NSButton(title: "Sign In", target: self, action: #selector(submit))
        signInButton.keyEquivalent = "\r"
        signInButton.bezelStyle = .rounded

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc

        [intro, fieldLabel, field, statusLabel, signInButton, cancelButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            fieldLabel.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 18),
            fieldLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            field.topAnchor.constraint(equalTo: fieldLabel.bottomAnchor, constant: 6),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            signInButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            signInButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            cancelButton.trailingAnchor.constraint(equalTo: signInButton.leadingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: signInButton.centerYAnchor),
        ])
    }

    @objc private func cancel() { window?.close() }

    @objc private func submit() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            setStatus("Paste the session cookie value first.", isError: true)
            return
        }
        signInButton.isEnabled = false
        setStatus("Signing in…", isError: false)
        onSubmit(value) { [weak self] ok in
            guard let self = self else { return }
            self.signInButton.isEnabled = true
            if ok {
                self.setStatus("Signed in — you can close this window.", isError: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.window?.close()
                }
            } else {
                self.setStatus(
                    "That cookie didn't authenticate. Make sure you're signed in " +
                    "in the browser and copied the current \(ClaudeWebURLs.sessionCookieName) value.",
                    isError: true)
            }
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }
}
