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
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Host:: callback implementations for PCSX2 running inside OpenEmu.
// Modeled after pcsx2-gsrunner/Main.cpp - most callbacks are stubs
// since OpenEmu provides the UI, window management, and input handling.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <OpenEmuBase/OERingBuffer.h>

#include "common/Pcsx2Defs.h"
#include "common/Console.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/Path.h"
#include "common/SettingsInterface.h"
#include "common/MemorySettingsInterface.h"
#include "common/StringUtil.h"
#include "common/SmallString.h"

#include "pcsx2/Host.h"
#include "pcsx2/VMManager.h"
#include "pcsx2/Config.h"
#include "pcsx2/GS/GS.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/SIO/Pad/Pad.h"

#include <mutex>
#include <optional>

// Forward declaration of the OpenEmu bridge globals (defined in PCSX2GameCore.mm)
namespace OpenEmuBridge {
    extern id<MTLDevice> g_metalDevice;
    extern id<MTLTexture> g_outputTexture;
    extern id g_renderDelegate;
    extern OERingBuffer *g_audioBuffer;

    extern std::atomic<uint32_t> g_buttonState[2];
    extern std::atomic<float> g_leftAnalogX[2];
    extern std::atomic<float> g_leftAnalogY[2];
    extern std::atomic<float> g_rightAnalogX[2];
    extern std::atomic<float> g_rightAnalogY[2];

    extern std::mutex g_frameMutex;
    extern std::condition_variable g_frameCV;
    extern std::atomic<bool> g_frameReady;
    extern std::atomic<bool> g_shutdownRequested;

    extern MemorySettingsInterface *g_settingsInterface;
    extern std::mutex g_settingsMutex;

    extern std::string g_biosPath;
    extern std::string g_supportPath;
    extern std::string g_savesPath;
}

#pragma mark - Translation (pass-through)

const char* Host::TranslateToCString(const std::string_view context, const std::string_view msg) {
    // Return the original string - no localization in OpenEmu context
    return msg.data();
}

std::string_view Host::TranslateToStringView(const std::string_view context, const std::string_view msg) {
    return msg;
}

std::string Host::TranslateToString(const std::string_view context, const std::string_view msg) {
    return std::string(msg);
}

std::string Host::TranslatePluralToString(const char* context, const char* msg, const char* disambiguation, int count) {
    return std::string(msg);
}

void Host::ClearTranslationCache() {}

#pragma mark - OSD Messages

void Host::AddOSDMessage(std::string message, float duration) {
    NSLog(@"[PCSX2] OSD: %s", message.c_str());
}

void Host::AddKeyedOSDMessage(std::string key, std::string message, float duration) {
    NSLog(@"[PCSX2] OSD [%s]: %s", key.c_str(), message.c_str());
}

void Host::AddIconOSDMessage(std::string key, const char* icon, const std::string_view message, float duration) {
    NSLog(@"[PCSX2] OSD [%s]: %.*s", key.c_str(), (int)message.size(), message.data());
}

void Host::RemoveKeyedOSDMessage(std::string key) {}
void Host::ClearOSDMessages() {}

#pragma mark - Error/Info Reporting

void Host::ReportInfoAsync(const std::string_view title, const std::string_view message) {
    NSLog(@"[PCSX2] Info: %.*s - %.*s", (int)title.size(), title.data(), (int)message.size(), message.data());
}

void Host::ReportFormattedInfoAsync(const std::string_view title, const char* format, ...) {
    va_list ap;
    va_start(ap, format);
    char buf[4096];
    vsnprintf(buf, sizeof(buf), format, ap);
    va_end(ap);
    NSLog(@"[PCSX2] Info: %.*s - %s", (int)title.size(), title.data(), buf);
}

void Host::ReportErrorAsync(const std::string_view title, const std::string_view message) {
    NSLog(@"[PCSX2] ERROR: %.*s - %.*s", (int)title.size(), title.data(), (int)message.size(), message.data());
}

void Host::ReportFormattedErrorAsync(const std::string_view title, const char* format, ...) {
    va_list ap;
    va_start(ap, format);
    char buf[4096];
    vsnprintf(buf, sizeof(buf), format, ap);
    va_end(ap);
    NSLog(@"[PCSX2] ERROR: %.*s - %s", (int)title.size(), title.data(), buf);
}

#pragma mark - Batch/NoGUI Mode

bool Host::InBatchMode() { return true; }
bool Host::InNoGUIMode() { return true; }

#pragma mark - URL/Clipboard

void Host::OpenURL(const std::string_view url) {}
bool Host::CopyTextToClipboard(const std::string_view text) { return false; }

#pragma mark - Settings Reset

bool Host::RequestResetSettings(bool folders, bool core, bool controllers, bool hotkeys, bool ui) {
    return false;
}

#pragma mark - Display

void Host::RequestResizeHostDisplay(s32 width, s32 height) {}

#pragma mark - Threading

void Host::RunOnCPUThread(std::function<void()> function, bool block) {
    // For now, execute inline since we're typically called from the CPU thread
    if (block) {
        function();
    } else {
        // Queue for later execution - in OpenEmu context, just run it
        function();
    }
}

void Host::RunOnGSThread(std::function<void()> function) {
    // Queue function to GS thread - for now execute inline
    function();
}

#pragma mark - Game List

void Host::RefreshGameListAsync(bool invalidate_cache) {}
void Host::CancelGameListRefresh() {}

#pragma mark - VM Shutdown

void Host::RequestVMShutdown(bool allow_confirm, bool allow_save_state, bool default_save_state) {
    NSLog(@"[PCSX2] Host::RequestVMShutdown called (confirm=%d, save=%d, default=%d)",
          allow_confirm, allow_save_state, default_save_state);
    OpenEmuBridge::g_shutdownRequested = true;
}

#pragma mark - HTTP

std::string Host::GetHTTPUserAgent() {
    return "PCSX2-OpenEmu";
}

#pragma mark - Base Settings Getters

std::string Host::GetBaseStringSettingValue(const char* section, const char* key, const char* default_value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface) {
        std::string value;
        if (OpenEmuBridge::g_settingsInterface->GetStringValue(section, key, &value))
            return value;
    }
    return default_value ? default_value : "";
}

SmallString Host::GetBaseSmallStringSettingValue(const char* section, const char* key, const char* default_value) {
    std::string val = GetBaseStringSettingValue(section, key, default_value);
    return SmallString(std::string_view(val));
}

TinyString Host::GetBaseTinyStringSettingValue(const char* section, const char* key, const char* default_value) {
    std::string val = GetBaseStringSettingValue(section, key, default_value);
    return TinyString(std::string_view(val));
}

bool Host::GetBaseBoolSettingValue(const char* section, const char* key, bool default_value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface) {
        bool value;
        if (OpenEmuBridge::g_settingsInterface->GetBoolValue(section, key, &value))
            return value;
    }
    return default_value;
}

int Host::GetBaseIntSettingValue(const char* section, const char* key, int default_value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface) {
        int value;
        if (OpenEmuBridge::g_settingsInterface->GetIntValue(section, key, &value))
            return value;
    }
    return default_value;
}

uint Host::GetBaseUIntSettingValue(const char* section, const char* key, uint default_value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface) {
        uint value;
        if (OpenEmuBridge::g_settingsInterface->GetUIntValue(section, key, &value))
            return value;
    }
    return default_value;
}

float Host::GetBaseFloatSettingValue(const char* section, const char* key, float default_value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface) {
        float value;
        if (OpenEmuBridge::g_settingsInterface->GetFloatValue(section, key, &value))
            return value;
    }
    return default_value;
}

double Host::GetBaseDoubleSettingValue(const char* section, const char* key, double default_value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface) {
        double value;
        if (OpenEmuBridge::g_settingsInterface->GetDoubleValue(section, key, &value))
            return value;
    }
    return default_value;
}

std::vector<std::string> Host::GetBaseStringListSetting(const char* section, const char* key) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        return OpenEmuBridge::g_settingsInterface->GetStringList(section, key);
    return {};
}

#pragma mark - Base Settings Setters

void Host::SetBaseBoolSettingValue(const char* section, const char* key, bool value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        OpenEmuBridge::g_settingsInterface->SetBoolValue(section, key, value);
}

void Host::SetBaseIntSettingValue(const char* section, const char* key, int value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        OpenEmuBridge::g_settingsInterface->SetIntValue(section, key, value);
}

void Host::SetBaseUIntSettingValue(const char* section, const char* key, uint value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        OpenEmuBridge::g_settingsInterface->SetUIntValue(section, key, value);
}

void Host::SetBaseFloatSettingValue(const char* section, const char* key, float value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        OpenEmuBridge::g_settingsInterface->SetFloatValue(section, key, value);
}

void Host::SetBaseStringSettingValue(const char* section, const char* key, const char* value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        OpenEmuBridge::g_settingsInterface->SetStringValue(section, key, value);
}

void Host::SetBaseStringListSettingValue(const char* section, const char* key, const std::vector<std::string>& values) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        OpenEmuBridge::g_settingsInterface->SetStringList(section, key, values);
}

bool Host::AddBaseValueToStringList(const char* section, const char* key, const char* value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        return OpenEmuBridge::g_settingsInterface->AddToStringList(section, key, value);
    return false;
}

bool Host::RemoveBaseValueFromStringList(const char* section, const char* key, const char* value) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        return OpenEmuBridge::g_settingsInterface->RemoveFromStringList(section, key, value);
    return false;
}

bool Host::ContainsBaseSettingValue(const char* section, const char* key) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        return OpenEmuBridge::g_settingsInterface->ContainsValue(section, key);
    return false;
}

void Host::RemoveBaseSettingValue(const char* section, const char* key) {
    std::lock_guard<std::mutex> lock(OpenEmuBridge::g_settingsMutex);
    if (OpenEmuBridge::g_settingsInterface)
        OpenEmuBridge::g_settingsInterface->DeleteValue(section, key);
}

void Host::CommitBaseSettingChanges() {
    // In-memory settings, no disk persistence needed
}

#pragma mark - Thread-safe Settings Getters

std::string Host::GetStringSettingValue(const char* section, const char* key, const char* default_value) {
    return GetBaseStringSettingValue(section, key, default_value);
}

SmallString Host::GetSmallStringSettingValue(const char* section, const char* key, const char* default_value) {
    return GetBaseSmallStringSettingValue(section, key, default_value);
}

TinyString Host::GetTinyStringSettingValue(const char* section, const char* key, const char* default_value) {
    return GetBaseTinyStringSettingValue(section, key, default_value);
}

bool Host::GetBoolSettingValue(const char* section, const char* key, bool default_value) {
    return GetBaseBoolSettingValue(section, key, default_value);
}

int Host::GetIntSettingValue(const char* section, const char* key, int default_value) {
    return GetBaseIntSettingValue(section, key, default_value);
}

uint Host::GetUIntSettingValue(const char* section, const char* key, uint default_value) {
    return GetBaseUIntSettingValue(section, key, default_value);
}

float Host::GetFloatSettingValue(const char* section, const char* key, float default_value) {
    return GetBaseFloatSettingValue(section, key, default_value);
}

double Host::GetDoubleSettingValue(const char* section, const char* key, double default_value) {
    return GetBaseDoubleSettingValue(section, key, default_value);
}

std::vector<std::string> Host::GetStringListSetting(const char* section, const char* key) {
    return GetBaseStringListSetting(section, key);
}

#pragma mark - Settings Lock/Interface

std::unique_lock<std::mutex> Host::GetSettingsLock() {
    return std::unique_lock<std::mutex>(OpenEmuBridge::g_settingsMutex);
}

std::unique_lock<std::mutex> Host::GetSecretsSettingsLock() {
    return std::unique_lock<std::mutex>(OpenEmuBridge::g_settingsMutex);
}

SettingsInterface* Host::GetSettingsInterface() {
    return OpenEmuBridge::g_settingsInterface;
}

void Host::SetDefaultUISettings(SettingsInterface& si) {}

#pragma mark - Progress Callback

std::unique_ptr<ProgressCallback> Host::CreateHostProgressCallback() {
    return nullptr;
}

#pragma mark - Locale

int Host::LocaleSensitiveCompare(std::string_view lhs, std::string_view rhs) {
    const int res = std::strncmp(lhs.data(), rhs.data(), std::min(lhs.size(), rhs.size()));
    if (res != 0)
        return res;
    return lhs.size() > rhs.size() ? 1 : (lhs.size() < rhs.size() ? -1 : 0);
}

#pragma mark - Settings/VM Callbacks

void Host::LoadSettings(SettingsInterface& si, std::unique_lock<std::mutex>& lock) {
    // Input sources are not loaded from settings in OpenEmu -
    // we inject input directly via Pad::SetControllerState
}

void Host::CheckForSettingsChanges(const Pcsx2Config& old_config) {}

void Host::OnVMStarting() {
    NSLog(@"[PCSX2] VM Starting");
}

void Host::OnVMStarted() {
    NSLog(@"[PCSX2] VM Started");
}

void Host::OnVMDestroyed() {
    NSLog(@"[PCSX2] VM Destroyed");
}

void Host::OnVMPaused() {
    NSLog(@"[PCSX2] VM Paused");
}

void Host::OnVMResumed() {
    NSLog(@"[PCSX2] VM Resumed");
}

void Host::OnPerformanceMetricsUpdated() {}

void Host::OnSaveStateLoading(const std::string_view filename) {
    NSLog(@"[PCSX2] Loading save state: %.*s", (int)filename.size(), filename.data());
}

void Host::OnSaveStateLoaded(const std::string_view filename, bool was_successful) {
    NSLog(@"[PCSX2] Save state loaded: %.*s (success: %d)", (int)filename.size(), filename.data(), was_successful);
}

void Host::OnSaveStateSaved(const std::string_view filename) {
    NSLog(@"[PCSX2] Save state saved: %.*s", (int)filename.size(), filename.data());
}

void Host::OnGameChanged(const std::string& title, const std::string& elf_override,
    const std::string& disc_path, const std::string& disc_serial, u32 disc_crc, u32 current_crc) {
    NSLog(@"[PCSX2] Game changed: %s (%s) CRC: %08X", title.c_str(), disc_serial.c_str(), disc_crc);
}

void Host::PumpMessagesOnCPUThread() {
    // This is called during CPU event tests from the CPU thread.
    // Check if OpenEmu has requested shutdown - trigger it from HERE (the CPU thread)
    // to avoid unsafe cross-thread longjmp in the interpreter's ExitExecution.
    if (OpenEmuBridge::g_shutdownRequested && VMManager::GetState() == VMState::Running) {
        VMManager::SetState(VMState::Stopping);
    }
}

#pragma mark - Render Window

std::optional<WindowInfo> Host::AcquireRenderWindow(bool recreate_window) {
    // Return a surfaceless WindowInfo - we provide the Metal device externally
    // via OpenEmuBridge::g_metalDevice
    WindowInfo wi;
    wi.type = WindowInfo::Type::Surfaceless;
    wi.surface_width = 640;
    wi.surface_height = 448;
    wi.surface_scale = 1.0f;
    wi.surface_refresh_rate = 59.94f;
    return wi;
}

void Host::ReleaseRenderWindow() {}

void Host::BeginPresentFrame() {
    // Called on the GS thread at frame boundaries.
    // In the OpenEmu Metal bridge, the frame blit to g_outputTexture
    // happens in the modified GSDeviceMTL::EndPresent().
}

#pragma mark - Input Manager Stubs

std::optional<u32> InputManager::ConvertHostKeyboardStringToCode(const std::string_view str) {
    return std::nullopt;
}

std::optional<std::string> InputManager::ConvertHostKeyboardCodeToString(u32 code) {
    return std::nullopt;
}

const char* InputManager::ConvertHostKeyboardCodeToIcon(u32 code) {
    return nullptr;
}

// Empty hotkey list
BEGIN_HOTKEY_LIST(g_host_hotkeys)
END_HOTKEY_LIST()

#pragma mark - Internal Settings Layers

namespace Host::Internal {
    static SettingsInterface* s_base_settings_layer = nullptr;
    static SettingsInterface* s_secrets_settings_layer = nullptr;
    static SettingsInterface* s_game_settings_layer = nullptr;
    static SettingsInterface* s_input_settings_layer = nullptr;

    SettingsInterface* GetBaseSettingsLayer() {
        return s_base_settings_layer;
    }

    SettingsInterface* GetSecretsSettingsLayer() {
        return s_secrets_settings_layer;
    }

    SettingsInterface* GetGameSettingsLayer() {
        return s_game_settings_layer;
    }

    SettingsInterface* GetInputSettingsLayer() {
        return s_input_settings_layer;
    }

    void SetBaseSettingsLayer(SettingsInterface* sif) {
        s_base_settings_layer = sif;
    }

    void SetSecretsSettingsLayer(SettingsInterface* sif) {
        s_secrets_settings_layer = sif;
    }

    void SetGameSettingsLayer(SettingsInterface* sif, std::unique_lock<std::mutex>& settings_lock) {
        s_game_settings_layer = sif;
    }

    void SetInputSettingsLayer(SettingsInterface* sif, std::unique_lock<std::mutex>& settings_lock) {
        s_input_settings_layer = sif;
    }

    s32 GetTranslatedStringImpl(const std::string_view context, const std::string_view msg,
                                 char* tbuf, size_t tbuf_space) {
        if (msg.size() < tbuf_space) {
            std::memcpy(tbuf, msg.data(), msg.size());
            tbuf[msg.size()] = '\0';
            return static_cast<s32>(msg.size());
        }
        return -1;
    }
}
