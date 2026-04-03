// Copyright (c) 2021, OpenEmu Team
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
import QuartzCore

@objc enum OEGridViewCellIndicationType: Int {
    case none, fileMissing, processing, dropOn, cloudOnly, pinned, downloading
}

@objc(OEGridViewCellIndicationLayer)
@objcMembers
final class GameCollectionViewItemIndicationLayer: CALayer {

    enum IndicationType {
        case none, fileMissing, processing, dropOn
    }

    private static let dropOnBackgroundColorRef = CGColor(red: 0.4, green: 0.361, blue: 0.871, alpha: 0.7)
    private static let indicationShadowColorRef = CGColor(red: 0.341, green: 0.0, blue: 0.012, alpha: 0.6)
    private static let missingFileBackgroundColorRef = CGColor(red: 0.992, green: 0.0, blue: 0.0, alpha: 0.4)
    private static let processingItemBackgroundColorRef = CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.7)
    private static let cloudBadgeBackgroundColorRef = CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.55)
    private static let pinBadgeBackgroundColorRef = CGColor(red: 0.3, green: 0.7, blue: 0.3, alpha: 0.85)
    private static let downloadingBackgroundColorRef = CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.65)
    private static let progressTrackColorRef = CGColor(white: 1.0, alpha: 0.3)
    private static let progressFillColorRef = CGColor(white: 1.0, alpha: 0.9)

    private static let rotationAnimation: CAKeyframeAnimation = {
        let stepCount = 12
        var spinnerValues = [Double]()
        spinnerValues.reserveCapacity(stepCount)

        for step in 0..<stepCount {
            spinnerValues.append(-1 * (.pi * 2) * Double(step) / Double(stepCount))
        }

        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.calculationMode = .discrete
        animation.duration = 1
        animation.repeatCount = .greatestFiniteMagnitude
        animation.isRemovedOnCompletion = false
        animation.values = spinnerValues

        return animation
    }()

    private static let pulseAnimation: CABasicAnimation = {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.4
        animation.toValue = 1.0
        animation.duration = 0.8
        animation.autoreverses = true
        animation.repeatCount = .greatestFiniteMagnitude
        return animation
    }()

    /// Download progress (0.0...1.0), or -1 for indeterminate.
    @objc var downloadProgress: Double = -1 {
        didSet {
            guard _type == .downloading else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setNeedsLayout()
            CATransaction.commit()
        }
    }

    private var _type: OEGridViewCellIndicationType = .none
    var type: OEGridViewCellIndicationType {
        get {
            return _type
        }
        set {
            guard _type != newValue else { return }
            _type = newValue

            if _type == .none {
                backgroundColor = nil
                sublayers?.forEach { $0.removeFromSuperlayer() }
            }
            else if type == .dropOn {
                sublayers?.forEach { $0.removeFromSuperlayer() }
                backgroundColor = Self.dropOnBackgroundColorRef
            }
            else if type == .cloudOnly || type == .pinned {
                sublayers?.forEach { $0.removeFromSuperlayer() }
                backgroundColor = nil

                let badge = CALayer()
                badge.actions = ["position" : NSNull()]
                badge.cornerRadius = 8
                badge.backgroundColor = type == .cloudOnly ? Self.cloudBadgeBackgroundColorRef : Self.pinBadgeBackgroundColorRef
                badge.shadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1.0)
                badge.shadowOffset = CGSize(width: 0, height: 1)
                badge.shadowRadius = 2
                badge.shadowOpacity = 0.5

                let symbolName = type == .cloudOnly ? "cloud" : "pin.fill"
                if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                    let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                    let tinted = img.withSymbolConfiguration(config)
                    let badgeImage = CALayer()
                    badgeImage.contents = tinted
                    badgeImage.contentsGravity = .resizeAspect
                    badge.addSublayer(badgeImage)
                }

                addSublayer(badge)
                setNeedsLayout()
            }
            else if type == .downloading {
                sublayers?.forEach { $0.removeFromSuperlayer() }
                backgroundColor = Self.downloadingBackgroundColorRef

                // Cloud download icon
                let iconLayer = CALayer()
                iconLayer.actions = ["position": NSNull()]
                if let img = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil) {
                    let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
                    let configured = img.withSymbolConfiguration(config)
                    iconLayer.contents = configured
                    iconLayer.contentsGravity = .resizeAspect
                }
                addSublayer(iconLayer)

                // Progress bar track
                let trackLayer = CALayer()
                trackLayer.actions = ["position": NSNull(), "bounds": NSNull()]
                trackLayer.backgroundColor = Self.progressTrackColorRef
                trackLayer.cornerRadius = 2
                trackLayer.name = "progressTrack"
                addSublayer(trackLayer)

                // Progress bar fill
                let fillLayer = CALayer()
                fillLayer.actions = ["position": NSNull(), "bounds": NSNull()]
                fillLayer.backgroundColor = Self.progressFillColorRef
                fillLayer.cornerRadius = 2
                fillLayer.name = "progressFill"
                if downloadProgress < 0 {
                    fillLayer.add(Self.pulseAnimation, forKey: "pulse")
                }
                addSublayer(fillLayer)

                setNeedsLayout()
            }
            else {
                var sublayer: CALayer! = sublayers?.last
                if sublayer == nil {
                    sublayer = CALayer()
                    sublayer.actions = ["position" : NSNull()]
                    sublayer.shadowOffset = CGSize(width: 0, height: -1)
                    sublayer.shadowOpacity = 1
                    sublayer.shadowRadius = 1
                    sublayer.shadowColor = Self.indicationShadowColorRef

                    addSublayer(sublayer)
                } else {
                    sublayer.removeAllAnimations()
                }

                if type == .fileMissing {
                    backgroundColor = Self.missingFileBackgroundColorRef

                    let img = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { dstRect in
                        NSImage(named: "missing_rom")?.draw(in: dstRect)
                        return true
                    }
                    sublayer.contents = img
                }
                else if type == .processing {
                    backgroundColor = Self.processingItemBackgroundColorRef
                    sublayer.contents = NSImage(named: "spinner")
                    sublayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                    sublayer.anchorPointZ = 0
                    sublayer.add(Self.rotationAnimation, forKey: nil)
                }

                setNeedsLayout()
            }
        }
    }

    override func layoutSublayers() {
        guard let sublayer = sublayers?.last else { return }

        CATransaction.begin()
        defer { CATransaction.commit() }
        CATransaction.setDisableActions(true)

        if type == .fileMissing {
            let width = bounds.width * 0.45
            let height = width * 0.9
            let frame = CGRect(x: bounds.minX + (bounds.width - width) / 2,
                               y: bounds.minY + (bounds.height - height) / 2,
                               width: width,
                               height: height).integral

            sublayer.frame = frame
            (sublayer.contents as? NSImage)?.size = frame.size
        }
        else if type == .processing {
            let spinnerImage = NSImage(named: "spinner")!

            let spinnerImageSize = spinnerImage.size
            var frame = CGRect(x: (bounds.width - spinnerImageSize.width) / 2,
                               y: (bounds.height - spinnerImageSize.height) / 2,
                               width: spinnerImageSize.width,
                               height: spinnerImageSize.height).integral
            frame.size.height = frame.size.width
            sublayer.frame = frame
        }
        else if type == .cloudOnly || type == .pinned {
            let badgeSize: CGFloat = 20
            let padding: CGFloat = 4
            let badgeFrame = CGRect(
                x: bounds.maxX - badgeSize - padding,
                y: bounds.minY + padding,
                width: badgeSize,
                height: badgeSize
            ).integral
            sublayer.frame = badgeFrame
            sublayer.sublayers?.first?.frame = sublayer.bounds.insetBy(dx: 3, dy: 3)
        }
        else if type == .downloading {
            // Icon centered in upper portion
            let layers = sublayers ?? []
            if layers.count >= 1 {
                let iconSize: CGFloat = min(bounds.width * 0.3, 32)
                layers[0].frame = CGRect(
                    x: (bounds.width - iconSize) / 2,
                    y: (bounds.height - iconSize) / 2 + 8,
                    width: iconSize,
                    height: iconSize
                ).integral
            }
            // Progress bar track at bottom
            let barHeight: CGFloat = 4
            let barPadding: CGFloat = 12
            let barY: CGFloat = bounds.minY + 12
            let barWidth = bounds.width - barPadding * 2

            if layers.count >= 2 {
                layers[1].frame = CGRect(x: barPadding, y: barY, width: barWidth, height: barHeight)
            }
            // Progress bar fill
            if layers.count >= 3 {
                let fillWidth: CGFloat
                if downloadProgress < 0 {
                    fillWidth = barWidth  // indeterminate: full width with pulse
                } else {
                    fillWidth = max(barWidth * CGFloat(downloadProgress), barHeight)
                }
                layers[2].frame = CGRect(x: barPadding, y: barY, width: fillWidth, height: barHeight)
            }
        }
        else {
            sublayer.frame = bounds
        }
    }
}
