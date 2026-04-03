// Stub implementations for symbols required by PPSSPP but not available
// in this OpenEmu integration (camera, libretro proc address).
// Real FFmpeg libraries are linked for cutscene/video support.

#include <stdint.h>
#include <stddef.h>
#include <vector>
#include <string>

// Camera stubs (macOS camera not needed in OpenEmu)
std::vector<std::string> __mac_getDeviceList() { return {}; }
int __mac_startCapture(int width, int height) { return 0; }
int __mac_stopCapture() { return 0; }

extern "C" {

// libretro proc address stub
void *libretro_get_proc_address(const char *sym) { return NULL; }

} // extern "C"
