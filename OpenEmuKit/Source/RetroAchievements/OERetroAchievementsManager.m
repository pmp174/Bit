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

#import "OERetroAchievementsManager.h"

#import <OpenEmuBase/OEGameCore.h>

// Informal protocol declaring the achievement event methods we send to the game core owner.
// The actual OEGameCoreOwner protocol is defined in Swift; we declare these selectors here
// to avoid needing the generated Swift header at compile time.
@interface NSObject (OERetroAchievementsEvents)
- (void)achievementTriggeredWithTitle:(NSString *)title description:(NSString *)description points:(NSInteger)points badgeURL:(NSString * _Nullable)badgeURL;
- (void)achievementProgressWithTitle:(NSString *)title description:(NSString *)description progress:(NSString *)progress;
- (void)gameCompleted;
@end

// rcheevos headers
#include "rc_client.h"
#include "rc_consoles.h"
#include "rc_error.h"

// MARK: - Forward declaration for ivar access in C callbacks

@interface OERetroAchievementsManager () {
    @public
    OEGameCore *_gameCore;
    __weak id _gameCoreOwner;
    rc_client_t *_client;
    NSString *_systemIdentifier;
    NSString *_pendingMD5;
    BOOL _loggedIn;
}
- (void)_beginLoadGame:(NSString *)md5;
@end

// MARK: - Console ID Mapping

static uint32_t OEConsoleIDForSystemIdentifier(NSString *systemIdentifier) {
    static NSDictionary<NSString *, NSNumber *> *mapping = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mapping = @{
            @"openemu.system.nes"     : @(RC_CONSOLE_NINTENDO),
            @"openemu.system.snes"    : @(RC_CONSOLE_SUPER_NINTENDO),
            @"openemu.system.gb"      : @(RC_CONSOLE_GAMEBOY),
            @"openemu.system.gbc"     : @(RC_CONSOLE_GAMEBOY_COLOR),
            @"openemu.system.gba"     : @(RC_CONSOLE_GAMEBOY_ADVANCE),
            @"openemu.system.n64"     : @(RC_CONSOLE_NINTENDO_64),
            @"openemu.system.gc"      : @(RC_CONSOLE_GAMECUBE),
            @"openemu.system.wii"     : @(RC_CONSOLE_WII),
            @"openemu.system.genesis" : @(RC_CONSOLE_MEGA_DRIVE),
            @"openemu.system.megaDrive" : @(RC_CONSOLE_MEGA_DRIVE),
            @"openemu.system.dc"      : @(RC_CONSOLE_DREAMCAST),
            @"openemu.system.psx"     : @(RC_CONSOLE_PLAYSTATION),
            @"openemu.system.psp"     : @(RC_CONSOLE_PSP),
            @"openemu.system.pce"     : @(RC_CONSOLE_PC_ENGINE),
            @"openemu.system.segaCD"  : @(RC_CONSOLE_SEGA_CD),
            @"openemu.system.32x"     : @(RC_CONSOLE_SEGA_32X),
            @"openemu.system.mastersystem" : @(RC_CONSOLE_MASTER_SYSTEM),
            @"openemu.system.gg"      : @(RC_CONSOLE_GAME_GEAR),
            @"openemu.system.lynx"    : @(RC_CONSOLE_ATARI_LYNX),
            @"openemu.system.jaguar"  : @(RC_CONSOLE_ATARI_JAGUAR),
            @"openemu.system.nds"     : @(RC_CONSOLE_NINTENDO_DS),
            @"openemu.system.atari2600" : @(RC_CONSOLE_ATARI_2600),
            @"openemu.system.vb"      : @(RC_CONSOLE_VIRTUAL_BOY),
            @"openemu.system.ngp"     : @(RC_CONSOLE_NEOGEO_POCKET),
            @"openemu.system.pokemonMini" : @(RC_CONSOLE_POKEMON_MINI),
            @"openemu.system.msx"     : @(RC_CONSOLE_MSX),
        };
    });

    NSNumber *consoleID = mapping[systemIdentifier];
    return consoleID ? consoleID.unsignedIntValue : RC_CONSOLE_UNKNOWN;
}

// MARK: - C Callbacks

static uint32_t oe_read_memory(uint32_t address, uint8_t *buffer, uint32_t num_bytes, rc_client_t *client) {
    OERetroAchievementsManager *manager = (__bridge OERetroAchievementsManager *)rc_client_get_userdata(client);
    OEGameCore *core = manager->_gameCore;

    if (![core respondsToSelector:@selector(achievementReadMemoryAtAddress:buffer:size:)]) {
        return 0;
    }

    return (uint32_t)[core achievementReadMemoryAtAddress:address buffer:buffer size:num_bytes];
}

static void oe_server_call(const rc_api_request_t *request,
                           rc_client_server_callback_t callback,
                           void *callback_data,
                           rc_client_t *client) {
    NSString *urlString = [NSString stringWithUTF8String:request->url];
    NSMutableURLRequest *urlRequest;

    if (request->post_data) {
        urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        urlRequest.HTTPMethod = @"POST";
        urlRequest.HTTPBody = [NSData dataWithBytes:request->post_data length:strlen(request->post_data)];
        if (request->content_type) {
            [urlRequest setValue:[NSString stringWithUTF8String:request->content_type]
             forHTTPHeaderField:@"Content-Type"];
        } else {
            [urlRequest setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        }
    } else {
        urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    }

    urlRequest.timeoutInterval = 30;

    char userAgent[256];
    rc_client_get_user_agent_clause(client, userAgent, sizeof(userAgent));
    NSString *ua = [NSString stringWithFormat:@"Bit/1.0 %s", userAgent];
    [urlRequest setValue:ua forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:urlRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            rc_api_server_response_t serverResponse;
            memset(&serverResponse, 0, sizeof(serverResponse));

            if (error || !data) {
                serverResponse.http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
                NSLog(@"[RetroAchievements] Server call error: %@", error.localizedDescription);
            } else {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                serverResponse.http_status_code = (int)httpResponse.statusCode;
                serverResponse.body = (const char *)data.bytes;
                serverResponse.body_length = data.length;
            }

            callback(&serverResponse, callback_data);
        }];

    [task resume];
}

static void oe_event_handler(const rc_client_event_t *event, rc_client_t *client) {
    OERetroAchievementsManager *manager = (__bridge OERetroAchievementsManager *)rc_client_get_userdata(client);
    id owner = manager->_gameCoreOwner;

    // Do NOT use respondsToSelector: on `owner`. The owner is typically an
    // NSXPCConnection proxy (NSProxy subclass), which does not reliably report
    // YES for @objc optional protocol methods. Send the message directly —
    // the NSXPCInterface already declares these selectors, and messaging nil
    // is safe in ObjC.

    switch (event->type) {
        case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED: {
            if (!event->achievement) break;
            NSString *title = event->achievement->title
                ? [NSString stringWithUTF8String:event->achievement->title] : @"Achievement";
            NSString *desc = event->achievement->description
                ? [NSString stringWithUTF8String:event->achievement->description] : @"";
            NSInteger points = (NSInteger)event->achievement->points;
            NSString *badgeURL = event->achievement->badge_url
                ? [NSString stringWithUTF8String:event->achievement->badge_url] : nil;

            NSLog(@"[RetroAchievements] Achievement triggered: %@ (%ld pts)", title, (long)points);
            [owner achievementTriggeredWithTitle:title description:desc points:points badgeURL:badgeURL];
            break;
        }

        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE: {
            if (!event->achievement) break;
            NSString *title = event->achievement->title
                ? [NSString stringWithUTF8String:event->achievement->title] : @"";
            NSString *desc = event->achievement->description
                ? [NSString stringWithUTF8String:event->achievement->description] : @"";
            NSString *progress = [NSString stringWithUTF8String:event->achievement->measured_progress];

            [owner achievementProgressWithTitle:title description:desc progress:progress];
            break;
        }

        case RC_CLIENT_EVENT_GAME_COMPLETED: {
            NSLog(@"[RetroAchievements] Game completed!");
            [owner gameCompleted];
            break;
        }

        case RC_CLIENT_EVENT_SERVER_ERROR: {
            if (event->server_error) {
                NSLog(@"[RetroAchievements] Server error: %s (API: %s)",
                      event->server_error->error_message ?: "unknown",
                      event->server_error->api ?: "unknown");
            }
            break;
        }

        case RC_CLIENT_EVENT_DISCONNECTED:
            NSLog(@"[RetroAchievements] Disconnected - unlocks pending");
            break;

        case RC_CLIENT_EVENT_RECONNECTED:
            NSLog(@"[RetroAchievements] Reconnected - pending unlocks submitted");
            break;

        default:
            break;
    }
}

static void oe_login_callback(int result, const char *error_message, rc_client_t *client, void *userdata) {
    OERetroAchievementsManager *manager = (__bridge OERetroAchievementsManager *)rc_client_get_userdata(client);

    if (result == RC_OK) {
        const rc_client_user_t *user = rc_client_get_user_info(client);
        NSLog(@"[RetroAchievements] Login successful: %s", user ? user->display_name : "unknown");
        manager->_loggedIn = YES;

        if (manager->_pendingMD5) {
            [manager _beginLoadGame:manager->_pendingMD5];
            manager->_pendingMD5 = nil;
        }
    } else {
        NSLog(@"[RetroAchievements] Login failed: %s (code %d)",
              error_message ?: "unknown", result);
    }
}

static void oe_load_game_callback(int result, const char *error_message, rc_client_t *client, void *userdata) {
    if (result == RC_OK) {
        const rc_client_game_t *game = rc_client_get_game_info(client);
        if (game && game->title) {
            NSLog(@"[RetroAchievements] Game loaded: %s (ID: %u)", game->title, game->id);
        } else {
            NSLog(@"[RetroAchievements] Game loaded (unidentified)");
        }
    } else if (result == RC_NO_GAME_LOADED) {
        NSLog(@"[RetroAchievements] Game not found in RetroAchievements database");
    } else {
        NSLog(@"[RetroAchievements] Game load failed: %s (code %d)",
              error_message ?: "unknown", result);
    }
}

static void oe_log_message(const char *message, const rc_client_t *client) {
    NSLog(@"[rcheevos] %s", message);
}

// MARK: - Implementation

@implementation OERetroAchievementsManager

- (instancetype)initWithGameCore:(OEGameCore *)gameCore
                  gameCoreOwner:(id)owner
               systemIdentifier:(NSString *)systemIdentifier {
    self = [super init];
    if (self) {
        _gameCore = gameCore;
        _gameCoreOwner = owner;
        _systemIdentifier = [systemIdentifier copy];
        _loggedIn = NO;

        _client = rc_client_create(oe_read_memory, oe_server_call);
        rc_client_set_userdata(_client, (__bridge void *)self);
        rc_client_set_event_handler(_client, oe_event_handler);
        rc_client_enable_logging(_client, RC_CLIENT_LOG_LEVEL_INFO, oe_log_message);

        // Disable hardcore mode by default for emulator use
        rc_client_set_hardcore_enabled(_client, 0);

        NSLog(@"[RetroAchievements] Manager initialized for system: %@", systemIdentifier);
    }
    return self;
}

- (void)loginWithUsername:(NSString *)username token:(NSString *)token {
    NSLog(@"[RetroAchievements] Logging in as %@...", username);
    rc_client_begin_login_with_token(_client, username.UTF8String, token.UTF8String,
                                     oe_login_callback, NULL);
}

- (void)loadGameWithMD5:(NSString *)md5 {
    if (!md5 || md5.length == 0) {
        NSLog(@"[RetroAchievements] No MD5 hash provided, skipping game load");
        return;
    }

    if (_loggedIn) {
        [self _beginLoadGame:md5];
    } else {
        _pendingMD5 = [md5 copy];
        NSLog(@"[RetroAchievements] Game load deferred until login completes (MD5: %@)", md5);
    }
}

- (void)_beginLoadGame:(NSString *)md5 {
    NSLog(@"[RetroAchievements] Loading game with MD5: %@", md5);
    rc_client_begin_load_game(_client, md5.UTF8String, oe_load_game_callback, NULL);
}

- (void)doFrame {
    if (_client && _loggedIn) {
        rc_client_do_frame(_client);
    }
}

- (void)shutdown {
    if (_client) {
        rc_client_unload_game(_client);
        rc_client_destroy(_client);
        _client = NULL;
        NSLog(@"[RetroAchievements] Manager shut down");
    }
}

- (void)dealloc {
    [self shutdown];
}

@end
