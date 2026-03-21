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

enum OEAppearance {
    
    enum Application: Int {
        case system, dark, light
        static var key = "OEAppearance"
    }
    
    enum HUDBar: Int {
        case vibrant, dark
        static var key = "OEHUDBarAppearance"
    }
    
    enum ControlsPrefs: Int {
        case wood, vibrant, woodVibrant
        static var key = "OEControlsPrefsAppearance"
    }
    
    /// The user-selected tint color name. When set, the sidebar and library use this tint overlay.
    /// When nil or "none", the app uses standard dark/light mode with no tint.
    enum TintColor: String, CaseIterable {
        case none = "none"
        case blue = "blue"
        case purple = "purple"
        case red = "red"
        case orange = "orange"
        case yellow = "yellow"
        case green = "green"
        case indigo = "indigo"
        case darkBlue = "darkBlue"

        static var key = "OETintColor"

        var displayName: String {
            switch self {
            case .none:     return "None"
            case .blue:     return "Blue"
            case .purple:   return "Purple"
            case .red:      return "Red"
            case .orange:   return "Orange"
            case .yellow:   return "Yellow"
            case .green:    return "Green"
            case .indigo:   return "Indigo"
            case .darkBlue: return "Dark Blue"
            }
        }

        var color: NSColor? {
            switch self {
            case .none:     return nil
            case .blue:     return NSColor(calibratedRed: 0x00/255.0, green: 0x9E/255.0, blue: 0xDC/255.0, alpha: 1.0)
            case .purple:   return NSColor(calibratedRed: 0xEA/255.0, green: 0x4C/255.0, blue: 0x89/255.0, alpha: 1.0)
            case .red:      return NSColor(calibratedRed: 0xC5/255.0, green: 0x51/255.0, blue: 0x52/255.0, alpha: 1.0)
            case .orange:   return NSColor(calibratedRed: 0xE1/255.0, green: 0x94/255.0, blue: 0x33/255.0, alpha: 1.0)
            case .yellow:   return NSColor(calibratedRed: 0xF2/255.0, green: 0xBE/255.0, blue: 0x2E/255.0, alpha: 1.0)
            case .green:    return NSColor(calibratedRed: 0x4E/255.0, green: 0x8A/255.0, blue: 0x2E/255.0, alpha: 1.0)
            case .indigo:   return NSColor(calibratedRed: 0x43/255.0, green: 0x2E/255.0, blue: 0x6E/255.0, alpha: 1.0)
            case .darkBlue: return NSColor(calibratedRed: 0x15/255.0, green: 0x19/255.0, blue: 0x46/255.0, alpha: 1.0)
            }
        }
    }
    
    static var application: Application {
        Application(rawValue: UserDefaults.standard.integer(forKey: Application.key)) ?? .system
    }
    
    static var hudBar: HUDBar {
        HUDBar(rawValue: UserDefaults.standard.integer(forKey: HUDBar.key)) ?? .vibrant
    }
    
    static var controlsPrefs: ControlsPrefs {
        ControlsPrefs(rawValue: UserDefaults.standard.integer(forKey: ControlsPrefs.key)) ?? .vibrant
    }
    
    static var tintColor: TintColor {
        guard let raw = UserDefaults.standard.string(forKey: TintColor.key) else { return .none }
        return TintColor(rawValue: raw) ?? .none
    }
    
    /// Returns the user's selected tint color, or the system accent color as fallback.
    /// Use this for selection highlights, checkboxes, and other accent UI.
    static var accentColor: NSColor {
        tintColor.color ?? .controlAccentColor
    }
}

// MARK: - ObjC Bridge

/// Provides access to OEAppearance tint colors from Objective-C code.
@objc final class OEAppearanceHelper: NSObject {
    
    /// Returns the user's selected tint color for selection highlights, or the system accent color.
    @objc static var accentColor: NSColor {
        OEAppearance.accentColor
    }
}
