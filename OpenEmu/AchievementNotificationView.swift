// Copyright (c) 2025, OpenEmu Team
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

/// A banner view that slides in from the top-right corner of the game view
/// to display achievement unlock notifications.
final class AchievementNotificationView: NSView {

    private let trophyImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let pointsLabel = NSTextField(labelWithString: "")

    private var dismissTimer: Timer?
    private var topConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 10

        // Trophy icon
        trophyImageView.image = NSImage(systemSymbolName: "trophy.fill", accessibilityDescription: "Achievement")
        trophyImageView.contentTintColor = .systemYellow
        trophyImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trophyImageView)

        // Title
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Description
        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(descriptionLabel)

        // Points
        pointsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        pointsLabel.textColor = .systemYellow
        pointsLabel.alignment = .right
        pointsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pointsLabel)

        NSLayoutConstraint.activate([
            // Trophy icon
            trophyImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            trophyImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            trophyImageView.widthAnchor.constraint(equalToConstant: 28),
            trophyImageView.heightAnchor.constraint(equalToConstant: 28),

            // Title
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: trophyImageView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pointsLabel.leadingAnchor, constant: -8),

            // Description
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            descriptionLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),

            // Points
            pointsLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pointsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pointsLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),

            // Fixed size
            widthAnchor.constraint(equalToConstant: 320),
            heightAnchor.constraint(equalToConstant: 56),
        ])
    }

    // MARK: - Public

    func show(in parentView: NSView, title: String, description: String, points: Int) {
        dismissTimer?.invalidate()

        titleLabel.stringValue = title
        descriptionLabel.stringValue = description
        pointsLabel.stringValue = points > 0 ? "\(points) pts" : ""

        translatesAutoresizingMaskIntoConstraints = false

        if superview !== parentView {
            removeFromSuperview()
            parentView.addSubview(self)
        }

        // Position off-screen initially (above the parent view)
        if topConstraint == nil {
            topConstraint = topAnchor.constraint(equalTo: parentView.topAnchor, constant: -66)
            trailingConstraint = trailingAnchor.constraint(equalTo: parentView.trailingAnchor, constant: -10)
            topConstraint?.isActive = true
            trailingConstraint?.isActive = true
        } else {
            topConstraint?.constant = -66
        }

        alphaValue = 0
        parentView.layoutSubtreeIfNeeded()

        // Slide in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
            self.topConstraint?.animator().constant = 10
            parentView.animator().layoutSubtreeIfNeeded()
        }

        // Auto-dismiss after 4 seconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let parentView = superview else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            self.topConstraint?.animator().constant = -66
            parentView.animator().layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.removeFromSuperview()
            self.topConstraint = nil
            self.trailingConstraint = nil
        })
    }
}
