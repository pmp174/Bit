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

#import <Foundation/Foundation.h>
#import <OpenEmuBase/OEGameCore.h>

@protocol OEGameCoreOwner;

NS_ASSUME_NONNULL_BEGIN

/// Manages the rcheevos rc_client lifecycle within the helper process.
/// One instance per game session.
@interface OERetroAchievementsManager : NSObject

/// Designated initializer.
/// @param gameCore The game core that provides memory access.
/// @param owner The game core owner for dispatching achievement events back to the main app.
/// @param systemIdentifier The OpenEmu system identifier (e.g. "openemu.system.snes").
- (instancetype)initWithGameCore:(OEGameCore *)gameCore
                  gameCoreOwner:(id<OEGameCoreOwner>)owner
               systemIdentifier:(NSString *)systemIdentifier;

/// Login with a RetroAchievements API token.
- (void)loginWithUsername:(NSString *)username token:(NSString *)token;

/// Load achievements for the current game by its MD5 hash.
- (void)loadGameWithMD5:(NSString *)md5;

/// Process achievements for the current frame. Call once per frame from didExecute.
- (void)doFrame;

/// Unload the current game and clean up.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
