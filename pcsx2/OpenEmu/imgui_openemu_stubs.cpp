// Stub implementations for ImGui subsystem functions.
// OpenEmu handles all UI, so we provide no-op stubs for all ImGui,
// FullscreenUI, and ImGuiFullscreen functions called from PCSX2 core code.

#include "common/Pcsx2Defs.h"
#include "common/SmallString.h"

#include "pcsx2/Input/InputManager.h"
#include "pcsx2/ImGui/ImGuiManager.h"
#include "pcsx2/ImGui/FullscreenUI.h"
#include "pcsx2/ImGui/ImGuiFullscreen.h"
#include "pcsx2/ImGui/ImGuiOverlays.h"
#include "pcsx2/GS/Renderers/Common/GSTexture.h"

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>

// ============================================================================
// ImGuiManager stubs
// ============================================================================

void ImGuiManager::SetFonts(std::vector<FontInfo> info) {}
bool ImGuiManager::Initialize() { return true; }
bool ImGuiManager::InitializeFullscreenUI() { return true; }
void ImGuiManager::Shutdown(bool clear_state) {}
float ImGuiManager::GetWindowWidth() { return 640.0f; }
float ImGuiManager::GetWindowHeight() { return 448.0f; }
void ImGuiManager::WindowResized() {}
void ImGuiManager::RequestScaleUpdate() {}
void ImGuiManager::ReloadFonts() {}
void ImGuiManager::NewFrame() {}
void ImGuiManager::SkipFrame() {}
void ImGuiManager::RenderOSD() {}
void ImGuiManager::RenderOverlays() {}
float ImGuiManager::GetGlobalScale() { return 1.0f; }
ImFont* ImGuiManager::GetStandardFont() { return nullptr; }
ImFont* ImGuiManager::GetFixedFont() { return nullptr; }
ImFont* ImGuiManager::GetOSDFont() { return nullptr; }
float ImGuiManager::GetFontSizeStandard() { return 16.0f; }
float ImGuiManager::GetFontSizeMedium() { return 14.0f; }
float ImGuiManager::GetFontSizeLarge() { return 22.0f; }
bool ImGuiManager::WantsTextInput() { return false; }
bool ImGuiManager::WantsMouseInput() { return false; }
void ImGuiManager::AddTextInput(std::string str) {}
void ImGuiManager::UpdateMousePosition(float x, float y) {}
bool ImGuiManager::ProcessPointerButtonEvent(InputBindingKey key, float value) { return false; }
bool ImGuiManager::ProcessPointerAxisEvent(InputBindingKey key, float value) { return false; }
bool ImGuiManager::ProcessHostKeyEvent(InputBindingKey key, float value) { return false; }
bool ImGuiManager::ProcessGenericInputEvent(GenericInputBinding key, InputLayout layout, float value) { return false; }
void ImGuiManager::SwapGamepadNorthWest(bool value) {}
bool ImGuiManager::IsGamepadNorthWestSwapped() { return false; }
void ImGuiManager::SetSoftwareCursor(u32 index, std::string image_path, float image_scale, u32 multiply_color) {}
bool ImGuiManager::HasSoftwareCursor(u32 index) { return false; }
void ImGuiManager::ClearSoftwareCursor(u32 index) {}
void ImGuiManager::SetSoftwareCursorPosition(u32 index, float pos_x, float pos_y) {}
std::string ImGuiManager::StripIconCharacters(std::string_view str) { return std::string(str); }

// ============================================================================
// FullscreenUI stubs
// ============================================================================

bool FullscreenUI::Initialize() { return true; }
bool FullscreenUI::IsInitialized() { return false; }
void FullscreenUI::ReloadSvgResources() {}
bool FullscreenUI::HasActiveWindow() { return false; }
void FullscreenUI::CheckForConfigChanges(const Pcsx2Config& old_config) {}
void FullscreenUI::OnVMStarted() {}
void FullscreenUI::OnVMDestroyed() {}
void FullscreenUI::GameChanged(std::string title, std::string path, std::string serial, u32 disc_crc, u32 crc) {}
void FullscreenUI::OpenPauseMenu() {}
bool FullscreenUI::OpenAchievementsWindow() { return false; }
bool FullscreenUI::OpenLeaderboardsWindow() { return false; }
void FullscreenUI::ReportStateLoadError(const std::string& message, std::optional<s32> slot, bool backup) {}
void FullscreenUI::ReportStateSaveError(const std::string& message, std::optional<s32> slot) {}
bool FullscreenUI::IsAchievementsWindowOpen() { return false; }
bool FullscreenUI::IsLeaderboardsWindowOpen() { return false; }
void FullscreenUI::ReturnToPreviousWindow() {}
void FullscreenUI::ReturnToMainWindow() {}
void FullscreenUI::SetStandardSelectionFooterText(bool back_instead_of_cancel) {}
void FullscreenUI::LocaleChanged() {}
void FullscreenUI::GamepadLayoutChanged() {}
void FullscreenUI::PreferEnglishGameListChanged() {}
void FullscreenUI::Shutdown(bool clear_state) {}
void FullscreenUI::Render() {}
void FullscreenUI::InvalidateCoverCache() {}
TinyString FullscreenUI::TimeToPrintableString(time_t t) { return TinyString(); }
bool FullscreenUI::CreateHardDriveWithProgress(const std::string& filePath, int sizeInGB, bool use48BitLBA) { return false; }
void FullscreenUI::CancelAllHddOperations() {}

// ============================================================================
// ImGuiFullscreen stubs - extern globals
// ============================================================================

namespace ImGuiFullscreen
{
	std::pair<ImFont*, float> g_standard_font = {nullptr, 16.0f};
	std::pair<ImFont*, float> g_medium_font = {nullptr, 14.0f};
	std::pair<ImFont*, float> g_large_font = {nullptr, 22.0f};

	float g_layout_scale = 1.0f;
	float g_rcp_layout_scale = 1.0f;
	float g_layout_padding_left = 0.0f;
	float g_layout_padding_top = 0.0f;

	ImVec4 UIBackgroundColor = ImVec4(0.13f, 0.13f, 0.13f, 1.0f);
	ImVec4 UIBackgroundTextColor = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
	ImVec4 UIBackgroundLineColor = ImVec4(0.25f, 0.25f, 0.25f, 1.0f);
	ImVec4 UIBackgroundHighlightColor = ImVec4(0.2f, 0.2f, 0.2f, 1.0f);
	ImVec4 UIPopupBackgroundColor = ImVec4(0.13f, 0.13f, 0.13f, 0.95f);
	ImVec4 UIDisabledColor = ImVec4(0.5f, 0.5f, 0.5f, 1.0f);
	ImVec4 UIPrimaryColor = ImVec4(0.26f, 0.59f, 0.98f, 1.0f);
	ImVec4 UIPrimaryLightColor = ImVec4(0.46f, 0.79f, 1.0f, 1.0f);
	ImVec4 UIPrimaryDarkColor = ImVec4(0.06f, 0.39f, 0.78f, 1.0f);
	ImVec4 UIPrimaryTextColor = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
	ImVec4 UITextHighlightColor = ImVec4(0.26f, 0.59f, 0.98f, 1.0f);
	ImVec4 UIPrimaryLineColor = ImVec4(0.26f, 0.59f, 0.98f, 1.0f);
	ImVec4 UISecondaryColor = ImVec4(0.2f, 0.2f, 0.2f, 1.0f);
	ImVec4 UISecondaryStrongColor = ImVec4(0.3f, 0.3f, 0.3f, 1.0f);
	ImVec4 UISecondaryWeakColor = ImVec4(0.15f, 0.15f, 0.15f, 1.0f);
	ImVec4 UISecondaryTextColor = ImVec4(0.7f, 0.7f, 0.7f, 1.0f);

	// Function stubs
	ImRect CenterImage(const ImVec2& fit_size, const ImVec2& image_size, bool fill) { return ImRect(); }
	ImRect CenterImage(const ImRect& fit_rect, const ImVec2& image_size, bool fill) { return ImRect(); }
	bool Initialize(const char* placeholder_image_path) { return true; }
	void SetTheme(std::string_view theme) {}
	void SetFont(ImFont* standard_font) {}
	bool UpdateLayoutScale() { return false; }
	void UpdateFontScale() {}
	void Shutdown(bool clear_state) {}
	const std::shared_ptr<GSTexture>& GetPlaceholderTexture() { static std::shared_ptr<GSTexture> s; return s; }
	std::shared_ptr<GSTexture> LoadTexture(std::string_view path) { return nullptr; }
	GSTexture* GetCachedTexture(std::string_view name) { return nullptr; }
	GSTexture* GetCachedTextureAsync(std::string_view name) { return nullptr; }
	std::shared_ptr<GSTexture> LoadSvgTexture(std::string_view path, ImVec2 size, SvgScaling mode) { return nullptr; }
	GSTexture* GetCachedSvgTexture(std::string_view name, ImVec2 size, SvgScaling mode) { return nullptr; }
	GSTexture* GetCachedSvgTextureAsync(std::string_view name, ImVec2 size, SvgScaling mode) { return nullptr; }
	bool InvalidateCachedTexture(const std::string& path) { return false; }
	void UploadAsyncTextures() {}
	void BeginLayout() {}
	void EndLayout() {}
	void PushResetLayout() {}
	void PopResetLayout() {}
	void QueueResetFocus(FocusResetType type) {}
	bool ResetFocusHere() { return false; }
	bool IsFocusResetQueued() { return false; }
	FocusResetType GetQueuedFocusResetType() { return FocusResetType::None; }
	void ForceKeyNavEnabled() {}
	bool WantsToCloseMenu() { return false; }
	void ResetCloseMenuIfNeeded() {}
	void PushPrimaryColor() {}
	void PopPrimaryColor() {}
	void DrawWindowTitle(const char* title) {}
	bool BeginFullscreenColumns(const char* title, float pos_y, bool expand_to_screen_width, bool footer) { return false; }
	void EndFullscreenColumns() {}
	bool BeginFullscreenColumnWindow(float start, float end, const char* name, const ImVec4& background) { return false; }
	void EndFullscreenColumnWindow() {}
	bool BeginFullscreenWindow(float left, float top, float width, float height, const char* name,
		const ImVec4& background, float rounding, const ImVec2& padding, ImGuiWindowFlags flags) { return false; }
	bool BeginFullscreenWindow(const ImVec2& position, const ImVec2& size, const char* name,
		const ImVec4& background, float rounding, const ImVec2& padding, ImGuiWindowFlags flags) { return false; }
	void EndFullscreenWindow() {}
	bool IsGamepadInputSource() { return false; }
	void ReportGamepadLayout(InputLayout layout) {}
	InputLayout GetGamepadLayout() { return InputLayout(0); }
	void CreateFooterTextString(SmallStringBase& dest, std::span<const std::pair<const char*, std::string_view>> items) {}
	void SetFullscreenFooterText(std::string_view text) {}
	void SetFullscreenFooterText(std::span<const std::pair<const char*, std::string_view>> items) {}
	void AppendToFullscreenFooterText(std::span<const std::pair<const char*, std::string_view>> items) {}
	void QueueFooterHint(std::span<const std::pair<const char*, std::string_view>> items) {}
	void DrawFullscreenFooter() {}
	void PrerenderMenuButtonBorder() {}
	void BeginMenuButtons(u32 num_items, float y_align, float x_padding, float y_padding, float item_height) {}
	void EndMenuButtons() {}
	void GetMenuButtonFrameBounds(float height, ImVec2* pos, ImVec2* size) {}
	bool MenuButtonFrame(const char* str_id, bool enabled, float height, bool* visible, bool* hovered, ImVec2* min, ImVec2* max,
		ImGuiButtonFlags flags, float hover_alpha) { return false; }
	void DrawMenuButtonFrame(const ImVec2& p_min, const ImVec2& p_max, ImU32 fill_col, bool border, float rounding) {}
	void ResetMenuButtonFrame() {}
	void MenuHeading(const char* title, bool draw_line) {}
	bool MenuHeadingButton(const char* title, const char* value, bool enabled, bool draw_line) { return false; }
	bool ActiveButton(const char* title, bool is_active, bool enabled, float height, std::pair<ImFont*, float> font) { return false; }
	bool ActiveButtonWithRightText(const char* title, const char* right_title, bool is_active, bool enabled,
		float height, std::pair<ImFont*, float> font) { return false; }
	bool MenuButton(const char* title, const char* summary, bool enabled, float height,
		std::pair<ImFont*, float> font, std::pair<ImFont*, float> summary_font) { return false; }
	bool MenuButtonWithoutSummary(const char* title, bool enabled, float height,
		std::pair<ImFont*, float> font, const ImVec2& text_align) { return false; }
	bool MenuButtonWithValue(const char* title, const char* summary, const char* value, bool enabled,
		float height, std::pair<ImFont*, float> font, std::pair<ImFont*, float> summary_font) { return false; }
	bool MenuImageButton(const char* title, const char* summary, ImTextureID user_texture_id, const ImVec2& image_size, bool enabled,
		float height, const ImVec2& uv0, const ImVec2& uv1, std::pair<ImFont*, float> font, std::pair<ImFont*, float> summary_font) { return false; }
	bool FloatingButton(const char* text, float x, float y, float width, float height,
		float anchor_x, float anchor_y, bool enabled, std::pair<ImFont*, float> font, ImVec2* out_position, bool repeat_button) { return false; }
	bool ToggleButton(const char* title, const char* summary, bool* v, bool enabled, float height,
		std::pair<ImFont*, float> font, std::pair<ImFont*, float> summary_font) { return false; }
	bool ThreeWayToggleButton(const char* title, const char* summary, std::optional<bool>* v, bool enabled,
		float height, std::pair<ImFont*, float> font, std::pair<ImFont*, float> summary_font) { return false; }
	bool EnumChoiceButtonImpl(const char* title, const char* summary, s32* value_pointer,
		const char* (*to_display_name_function)(s32 value, void* opaque), void* opaque, u32 count, bool enabled, float height,
		std::pair<ImFont*, float> font, std::pair<ImFont*, float> summary_font) { return false; }
	void BeginNavBar(float x_padding, float y_padding) {}
	void EndNavBar() {}
	void NavTitle(const char* title, float height, std::pair<ImFont*, float> font) {}
	void RightAlignNavButtons(u32 num_items, float item_width, float item_height) {}
	bool NavButton(const char* title, bool is_active, bool enabled, float width, float height, std::pair<ImFont*, float> font) { return false; }
	bool NavTab(const char* title, bool is_active, bool enabled, float width, float height, const ImVec4& background,
		std::pair<ImFont*, float> font) { return false; }
	bool BeginHorizontalMenu(const char* name, const ImVec2& position, const ImVec2& size, u32 num_items) { return false; }
	void EndHorizontalMenu() {}
	bool HorizontalMenuItem(GSTexture* icon, const ImVec2& icon_uv0, const ImVec2& icon_uv1, const char* title, const char* description) { return false; }
	bool HorizontalMenuItem(GSTexture* icon, const char* title, const char* description) { return false; }
	bool HorizontalMenuSvgItem(const char* svg_path, const char* title, const char* description, SvgScaling mode) { return false; }
	bool IsFileSelectorOpen() { return false; }
	void OpenFileSelector(std::string_view title, bool select_directory, FileSelectorCallback callback,
		FileSelectorFilters filters, std::string initial_directory) {}
	void CloseFileSelector() {}
	bool IsChoiceDialogOpen() { return false; }
	void OpenChoiceDialog(std::string_view title, bool checkable, ChoiceDialogOptions options, ChoiceDialogCallback callback) {}
	void CloseChoiceDialog() {}
	bool IsInputDialogOpen() { return false; }
	void OpenInputStringDialog(std::string title, std::string message, std::string caption, std::string ok_button_text,
		InputStringDialogCallback callback, std::string default_value, InputFilterType filter_type) {}
	void CloseInputDialog() {}
	bool IsMessageBoxDialogOpen() { return false; }
	void OpenConfirmMessageDialog(std::string title, std::string message, ConfirmMessageDialogCallback callback, bool default_yes,
		std::string yes_button_text, std::string no_button_text) {}
	void OpenInfoMessageDialog(std::string title, std::string message, InfoMessageDialogCallback callback, std::string button_text) {}
	void OpenMessageDialog(std::string title, std::string message, MessageDialogCallback callback, s32 default_index,
		std::string first_button_text, std::string second_button_text, std::string third_button_text) {}
	void CloseMessageDialog() {}
	float GetNotificationVerticalPosition() { return 0.0f; }
	float GetNotificationVerticalDirection() { return 1.0f; }
	void SetNotificationVerticalPosition(float position, float direction) {}
	void SetNotificationPosition(float horizontal_position, float vertical_position, float direction) {}
	void OpenProgressDialog(const char* str_id, std::string message, s32 min, s32 max, s32 value) {}
	void UpdateProgressDialog(const char* str_id, std::string message, s32 min, s32 max, s32 value) {}
	void CloseProgressDialog(const char* str_id) {}
	void AddNotification(std::string key, float duration, std::string title, std::string text, std::string image_path) {}
	void ClearNotifications() {}
	void ShowToast(std::string title, std::string message, float duration) {}
	void ClearToast() {}
	void GetChoiceDialogHelpText(SmallStringBase& dest) {}
	void GetFileSelectorHelpText(SmallStringBase& dest) {}
	void GetInputDialogHelpText(SmallStringBase& dest) {}
} // namespace ImGuiFullscreen

// ============================================================================
// ImGuiOverlays stubs
// ============================================================================

ImVec2 CalculateOSDPosition(OsdOverlayPos position, float margin, const ImVec2& text_size, float window_width, float window_height) {
	return ImVec2(0.0f, 0.0f);
}

ImVec2 CalculatePerformanceOverlayTextPosition(OsdOverlayPos position, float margin, const ImVec2& text_size, float window_width, float position_y) {
	return ImVec2(0.0f, 0.0f);
}

bool ShouldUseLeftAlignment(OsdOverlayPos position) { return false; }

// ============================================================================
// SaveStateSelectorUI stubs
// ============================================================================

namespace SaveStateSelectorUI
{
	void Open(float open_time) {}
	void RefreshList(const std::string& serial, u32 crc) {}
	void DestroyTextures() {}
	void Clear() {}
	void Close() {}
	bool IsOpen() { return false; }
	void SelectNextSlot(bool open_selector) {}
	void SelectPreviousSlot(bool open_selector) {}
	s32 GetCurrentSlot() { return 0; }
	void LoadCurrentSlot() {}
	void LoadCurrentBackupSlot() {}
	void SaveCurrentSlot() {}
} // namespace SaveStateSelectorUI

// ============================================================================
// InputRecordingUI extern
// ============================================================================

InputRecordingUI::InputRecordingData g_InputRecordingData;
