import Cocoa

/// The centred "mirror stopped" panel, carrying the button that rebuilds the
/// capture stream.
///
/// Lives on the mirror rather than in an alert or the title bar because a dead
/// stream has no other symptom - the window simply goes blank - so the failure
/// and the way out of it belong where the user is already looking. An alert
/// would also steal key focus, which is exactly what the mirror needs to keep.
///
/// Deliberately only the panel, and never a full-size scrim: capture dying does
/// not take the virtual display with it, so clicks and keystrokes outside the
/// panel must go on reaching it and the mirror must go on working as a keyboard
/// remote while it is blank.
final class CaptureErrorOverlay: NSView {
    /// Asked for a fresh stream. Not called while a reload is already in flight.
    var onReload: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Mirror stopped")
    private let detailLabel = NSTextField(labelWithString: "")
    private let reloadButton = NSButton()

    /// Fixed dark chrome rather than the system appearance: this panel sits on
    /// top of mirrored content of unknown brightness, so it has to supply its own
    /// contrast instead of inheriting the user's light or dark mode.
    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.94).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.95)
        titleLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.62)
        detailLabel.alignment = .center
        // A capture error's text is a whole sentence of CoreMedia prose, so the
        // label has to wrap rather than truncate - the useful part is usually at
        // the end.
        detailLabel.usesSingleLineMode = false
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 5
        detailLabel.cell?.wraps = true
        detailLabel.cell?.isScrollable = false
        detailLabel.preferredMaxLayoutWidth = 320

        reloadButton.title = "Reload Mirror"
        reloadButton.bezelStyle = .rounded
        reloadButton.controlSize = .large
        reloadButton.target = self
        reloadButton.action = #selector(reloadButtonClicked)
        // Clicking the button must not pull first responder away from the mirror:
        // that is what forwards keystrokes, and losing it would silently turn the
        // keyboard remote off at the moment the user was trying to fix it.
        reloadButton.refusesFirstResponder = true

        let stack = NSStackView(views: [titleLabel, detailLabel, reloadButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])

        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("CaptureErrorOverlay is built in code, never loaded from a nib.")
    }

    /// True between the user asking for a reload and that attempt resolving.
    private(set) var isReloading = false

    /// Reveals the panel, describing what went wrong.
    ///
    /// Safe to call repeatedly: a stream that fails on every attempt re-presents
    /// rather than stacking, and each presentation clears the in-flight state so
    /// the button is live again for the next try.
    func present(message: String) {
        detailLabel.stringValue = message
        setReloading(false)
        isHidden = false
    }

    /// Called for every frame that arrives, so it must stay cheap when there is
    /// nothing to do.
    func dismiss() {
        guard !isHidden else {
            return
        }
        isHidden = true
        setReloading(false)
    }

    /// Reflects an attempt in flight, so a slow rebuild does not read as a dead
    /// button and invite a second click that would cancel the first attempt's task.
    func setReloading(_ reloading: Bool) {
        isReloading = reloading
        reloadButton.title = reloading ? "Reloading…" : "Reload Mirror"
        reloadButton.isEnabled = !reloading
    }

    @objc private func reloadButtonClicked() {
        guard !isReloading else {
            return
        }
        onReload?()
    }

    /// The panel is a subview of the mirror, whose own `mouseDown` forwards a
    /// double click to the virtual display by warping the pointer onto it.
    /// NSView's default implementation passes unhandled clicks up to the
    /// superview, so without swallowing them here a double click anywhere on this
    /// panel would hand the pointer away mid-recovery.
    override func mouseDown(with _: NSEvent) {}

    override func rightMouseDown(with _: NSEvent) {}

    override func scrollWheel(with _: NSEvent) {}

    /// Likewise the mirror suppresses background window drags, and for the same
    /// reason this panel must not reintroduce one.
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}
