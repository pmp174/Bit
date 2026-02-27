// Copyright (c) 2024, OpenEmu Team
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

import Foundation

/// Configuration for the Google Drive Save Sync integration.
///
/// IMPORTANT: Before shipping, replace the placeholder values below with
/// credentials obtained from the Google Cloud Console.
///
/// Steps to obtain credentials:
/// 1. Go to https://console.cloud.google.com/
/// 2. Create (or select) a project.
/// 3. Enable the "Google Drive API".
/// 4. Under "Credentials", create an "OAuth 2.0 Client ID" of type "macOS" (Desktop).
/// 5. Copy the Client ID and Client Secret here.
/// 6. Add the redirect URI "com.openemu.OpenEmu:/oauth2callback" to your OAuth client.
enum OEGoogleDriveConfig {
    
    // MARK: - OAuth Credentials
    //
    // IMPORTANT: Real credentials are stored in OEGoogleDriveSecrets.swift (gitignored).
    // Copy OEGoogleDriveSecrets.template.swift → OEGoogleDriveSecrets.swift and fill in
    // your credentials from the Google Cloud Console. Never commit that file.
    //
    // If OEGoogleDriveSecrets.swift is absent (e.g. a CI build), sign-in will not work
    // but the rest of the app remains unaffected.

    /// Your Google API OAuth 2.0 Client ID (loaded from local secrets file).
    static var clientID: String { Self._clientID }
    
    /// Your Google API OAuth 2.0 Client Secret (loaded from local secrets file).
    static var clientSecret: String { Self._clientSecret }
    
    // MARK: - OAuth Endpoints
    
    static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint         = "https://oauth2.googleapis.com/token"
    static let redirectURI           = "com.openemu.OpenEmu:/oauth2callback"
    
    // MARK: - API Scopes
    
    /// Requests access to the hidden App Data folder only.
    /// This is the most privacy-respecting scope — the app cannot see any other Drive files.
    static let scopes = ["https://www.googleapis.com/auth/drive.appdata"]
    
    // MARK: - API Endpoints
    
    static let driveAPIBaseURL   = "https://www.googleapis.com/drive/v3"
    static let uploadAPIBaseURL  = "https://www.googleapis.com/upload/drive/v3"
    
    // MARK: - App Data Folder
    
    /// The special Google Drive folder name for hidden App Data.
    /// Files stored here are invisible to the user in Drive UI.
    static let appDataFolderName = "appDataFolder"
    
    // MARK: - Keychain
    
    /// The Keychain service name used to store OAuth tokens securely.
    static let keychainService = "com.openemu.GoogleDriveSaveSync"
    
    // MARK: - Sync Settings
    
    /// How long (in seconds) between automated background sync checks when a game is running.
    static let backgroundSyncInterval: TimeInterval = 300  // 5 minutes
    
    /// Maximum file size (in bytes) to upload in a single request (5 MB).
    static let singleUploadMaxBytes: Int = 5 * 1024 * 1024
}
