// Copyright (c) 2025, OpenEmu Team
// Stubs for PCSX2 functionality not needed in the OpenEmu integration.
// These provide link-time resolution for symbols referenced by the PCSX2 core
// that are normally provided by the Qt UI or other frontends.

#include "common/Pcsx2Defs.h"
#include "common/Error.h"
#include "common/WindowInfo.h"

#include "pcsx2/Host.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/GS/GS.h"
#include "pcsx2/ImGui/ImGuiManager.h"
#include "pcsx2/ImGui/FullscreenUI.h"
#include "pcsx2/ImGui/ImGuiFullscreen.h"
#include "pcsx2/Achievements.h"

#include <string>
#include <string_view>
#include <functional>
#include <optional>

// ============================================================================
// GS / Display stubs (declared in GS.h)
// ============================================================================

bool Host::IsFullscreen() { return false; }
void Host::SetFullscreen(bool enabled) {}
void Host::OnCaptureStarted(const std::string& filename) {}
void Host::OnCaptureStopped() {}

// ============================================================================
// Text input stubs (declared in ImGuiManager.h)
// ============================================================================

void Host::BeginTextInput() {}
void Host::EndTextInput() {}

// ============================================================================
// Input device notification stubs (declared in InputManager.h)
// ============================================================================

void Host::OnInputDeviceConnected(const std::string_view identifier, const std::string_view device_name) {}
void Host::OnInputDeviceDisconnected(const InputBindingKey key, const std::string_view identifier) {}

// ============================================================================
// Mouse mode stubs (declared in InputManager.h)
// ============================================================================

void Host::SetMouseMode(bool relative_mode, bool hide_cursor) {}
void Host::SetMouseLock(bool state) {}

// ============================================================================
// Window info stub (declared in InputManager.h)
// ============================================================================

std::optional<WindowInfo> Host::GetTopLevelWindowInfo() { return std::nullopt; }

// ============================================================================
// Application lifecycle stubs (declared in FullscreenUI.h)
// ============================================================================

void Host::RequestExitApplication(bool allow_confirm) {}
void Host::RequestExitBigPicture() {}

// ============================================================================
// Achievement stubs (declared in Achievements.h)
// ============================================================================

void Host::OnAchievementsLoginSuccess(const char* username, u32 points, u32 sc_points, u32 unread_messages) {}
void Host::OnAchievementsLoginRequested(Achievements::LoginRequestReason reason) {}
void Host::OnAchievementsHardcoreModeChanged(bool enabled) {}
void Host::OnAchievementsRefreshed() {}

// ============================================================================
// Cover downloader / memory card stubs (declared in FullscreenUI.h)
// ============================================================================

void Host::OnCoverDownloaderOpenRequested() {}
void Host::OnCreateMemoryCardOpenRequested() {}

// ============================================================================
// File selector stubs (declared in ImGuiFullscreen.h)
// ============================================================================

bool Host::ShouldPreferHostFileSelector() { return false; }

void Host::OpenHostFileSelectorAsync(std::string_view title, bool select_directory,
    FileSelectorCallback callback, FileSelectorFilters filters, std::string_view initial_directory) {
    callback(std::string());
}

// ============================================================================
// Locale stubs (declared in FullscreenUI.h)
// ============================================================================

bool Host::LocaleCircleConfirm() { return false; }
