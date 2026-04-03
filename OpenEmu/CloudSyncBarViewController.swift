// Copyright (c) 2020, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Cocoa

/// A sidebar bar view that displays cloud sync progress, matching the Game Scanner style.
final class CloudSyncBarViewController: NSViewController {

    static let barHeight: CGFloat = 46

    private var headlineLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!

    private lazy var cloudManager = OECloudStorageManager.shared

    private(set) var isBarVisible = false

    /// Called when the bar's visibility changes; the host should re-layout.
    var onLayoutNeeded: (() -> Void)?

    // MARK: - View

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: Self.barHeight))
        container.autoresizingMask = [.width]

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        headlineLabel = NSTextField(labelWithString: NSLocalizedString("Cloud Sync", comment: ""))
        headlineLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headlineLabel.textColor = .secondaryLabelColor
        headlineLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headlineLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1
        statusLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),

            headlineLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 5),
            headlineLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            headlineLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),

            statusLabel.topAnchor.constraint(equalTo: headlineLabel.bottomAnchor, constant: 1),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),

            progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 3),
            progressIndicator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            progressIndicator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
            progressIndicator.heightAnchor.constraint(equalToConstant: 4),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(syncDidChange),
                       name: OECloudStorageManager.statusDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(syncDidChange),
                       name: OECloudStorageManager.syncProgressDidChangeNotification, object: nil)

        updateSyncUI()
    }

    // MARK: - Notifications

    @objc private func syncDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateSyncUI()
        }
    }

    // MARK: - UI Updates

    private func updateSyncUI() {
        if cloudManager.isSyncing {
            let progress = cloudManager.syncProgress
            let message = cloudManager.syncStatusMessage

            progressIndicator.isHidden = false
            progressIndicator.doubleValue = progress

            if progress > 0 && progress < 1 {
                progressIndicator.isIndeterminate = false
                progressIndicator.startAnimation(nil)
            } else {
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
            }

            statusLabel.stringValue = message.isEmpty
                ? NSLocalizedString("Syncing\u{2026}", comment: "")
                : message

            if !isBarVisible {
                showBar(animated: true)
            }
        } else {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true

            statusLabel.stringValue = NSLocalizedString("Done", comment: "")

            // Hide bar after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.cloudManager.isSyncing else { return }
                self.hideBar(animated: true)
            }
        }
    }

    // MARK: - Visibility

    func showBar(animated: Bool) {
        guard !isBarVisible else { return }
        isBarVisible = true
        view.isHidden = false
        onLayoutNeeded?()
    }

    func hideBar(animated: Bool) {
        guard isBarVisible else { return }
        isBarVisible = false
        view.isHidden = true
        onLayoutNeeded?()
    }
}
