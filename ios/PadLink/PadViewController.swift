import UIKit

final class PadViewController: UIViewController {
    private let pad = GamepadView()
    private let connection = PadConnection()
    private let statusLabel = PaddedLabel()
    private let settingsButton = UIButton(type: .system)

    private enum Keys {
        static let host = "padlink.host"
        static let port = "padlink.port"
    }
    static let defaultPort: UInt16 = 28910

    private var savedHost: String {
        get { UserDefaults.standard.string(forKey: Keys.host) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.host) }
    }

    private var savedPort: UInt16 {
        get {
            let v = UserDefaults.standard.integer(forKey: Keys.port)
            return (1...65535).contains(v) ? UInt16(v) : Self.defaultPort
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: Keys.port) }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        pad.frame = view.bounds
        pad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pad)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.layer.cornerRadius = 11
        statusLabel.layer.masksToBounds = true
        statusLabel.isUserInteractionEnabled = true
        statusLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showSettings)))
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        settingsButton.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        settingsButton.tintColor = UIColor(white: 1, alpha: 0.6)
        settingsButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            statusLabel.heightAnchor.constraint(equalToConstant: 22),
            settingsButton.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            settingsButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 32),
            settingsButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        pad.onChange = { [weak self] state in self?.connection.send(state) }
        connection.onStatus = { [weak self] status in self?.render(status) }
        render(.idle)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: nil)
        nc.addObserver(self, selector: #selector(sceneWillDeactivate), name: UIScene.willDeactivateNotification, object: nil)
    }

    private var didPromptOnce = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if savedHost.isEmpty, !didPromptOnce {
            didPromptOnce = true
            showSettings()
        }
    }

    @objc private func sceneDidActivate() {
        reconnect()
    }

    @objc private func sceneWillDeactivate() {
        // Don't leave buttons stuck down on the PC.
        pad.reset()
        connection.send(pad.state)
    }

    private func reconnect() {
        if savedHost.isEmpty {
            connection.disconnect()
        } else {
            connection.connect(host: savedHost, port: savedPort)
        }
    }

    private func render(_ status: PadConnection.Status) {
        switch status {
        case .idle:
            statusLabel.text = "Not set up — tap to enter PC address"
            statusLabel.backgroundColor = UIColor.systemGray.withAlphaComponent(0.5)
        case .connecting:
            statusLabel.text = "Connecting to \(savedHost)…"
            statusLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.6)
        case .connected(let name):
            statusLabel.text = "Connected · \(name)"
            statusLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.6)
        case .noResponse:
            statusLabel.text = "No response from \(savedHost):\(savedPort) — is the server running?"
            statusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.6)
        }
    }

    @objc private func showSettings() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Connect to PC",
            message: "Enter the IP address shown by the PadLink server window on your PC. Both devices must be on the same Wi-Fi.",
            preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "PC IP address, e.g. 192.168.1.20"
            tf.text = self.savedHost
            tf.keyboardType = .numbersAndPunctuation
            tf.autocorrectionType = .no
            tf.autocapitalizationType = .none
            tf.clearButtonMode = .whileEditing
        }
        alert.addTextField { tf in
            tf.placeholder = "Port (default \(Self.defaultPort))"
            tf.text = String(self.savedPort)
            tf.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            guard let self = self, let fields = alert?.textFields else { return }
            self.savedHost = (fields[0].text ?? "").trimmingCharacters(in: .whitespaces)
            if let p = UInt16(fields[1].text ?? ""), p > 0 {
                self.savedPort = p
            } else {
                self.savedPort = Self.defaultPort
            }
            self.reconnect()
        })
        present(alert, animated: true)
    }
}

/// UILabel with horizontal padding, for the status pill.
final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height)
    }
}
