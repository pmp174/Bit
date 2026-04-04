// Stub discord_rpc.h for OpenEmu builds - Discord integration not needed
#pragma once

struct DiscordRichPresence {
    const char* state;
    const char* details;
    const char* largeImageKey;
    const char* largeImageText;
    const char* smallImageKey;
    const char* smallImageText;
    const char* partyId;
    int partySize;
    int partyMax;
    int64_t startTimestamp;
    int64_t endTimestamp;
};

struct DiscordEventHandlers {
    void (*ready)(const void*);
    void (*disconnected)(int, const char*);
    void (*errored)(int, const char*);
    void (*joinGame)(const char*);
    void (*spectateGame)(const char*);
    void (*joinRequest)(const void*);
};

inline void Discord_Initialize(const char*, DiscordEventHandlers*, int, const char*) {}
inline void Discord_Shutdown() {}
inline void Discord_ClearPresence() {}
inline void Discord_UpdatePresence(const DiscordRichPresence*) {}
inline void Discord_RunCallbacks() {}
