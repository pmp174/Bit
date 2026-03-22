// Stub implementations for symbols removed from the OpenEmu plugin build.
// Flycast's network, HTTP, and platform-specific UI features are not
// needed for the OpenEmu core plugin.

#include "types.h"
#include "network/naomi_network.h"
#include "network/output.h"
#include "network/net_handshake.h"
#include "network/netservice.h"
#include "oslib/http_client.h"
#include "oslib/oslib.h"
#include "input/dreampotato.h"
#include <string>
#include <vector>
#include <cstdarg>

// --- Network globals ---

NaomiNetwork naomiNetwork;
NetworkOutput networkOutput;

bool NaomiNetworkSupported() { return false; }

bool NaomiNetwork::receive(const sockaddr_in *addr, const NaomiNetwork::Packet *packet, u32 size) {
    (void)addr; (void)packet; (void)size;
    return false;
}

// --- NetworkHandshake stubs ---

NetworkHandshake *NetworkHandshake::instance = nullptr;

void NetworkHandshake::init() {}
void NetworkHandshake::term() {}

// --- net::modbba stubs ---

namespace net::modbba {

bool start() { return false; }
void stop() {}
void writeModem(u8 b) { (void)b; }
int readModem() { return -1; }
int modemAvailable() { return 0; }
void receiveEthFrame(const u8 *frame, u32 size) { (void)frame; (void)size; }

}

// --- picoTCP mutex stubs ---

extern "C" {

void *pico_mutex_init(void) { return nullptr; }
void pico_mutex_lock(void *mux) { (void)mux; }
void pico_mutex_unlock(void *mux) { (void)mux; }
void pico_mutex_deinit(void *mux) { (void)mux; }

}

// --- HTTP client stubs ---

namespace http {

void init() {}
void term() {}

int get(const std::string& url, std::vector<u8>& content, std::string& content_type) {
    (void)url; (void)content; (void)content_type;
    return -1;
}

int post(const std::string& url, const std::vector<PostField>& fields) {
    (void)url; (void)fields;
    return -1;
}

int post(const std::string& url, const char *payload, const char *contentType, std::vector<u8>& reply) {
    (void)url; (void)payload; (void)contentType; (void)reply;
    return -1;
}

}

// --- OS/Platform stubs ---

void os_DoEvents() {}

const char *getIosJitStatus() { return "N/A"; }

void os_VideoRoutingPublishFrameTexture(unsigned int texID, unsigned int texTarget, float w, float h) {
    (void)texID; (void)texTarget; (void)w; (void)h;
}

void os_VideoRoutingTermGL() {}

// --- dreampotato stubs ---

namespace dreampotato {
void update() {}
void term() {}
}

// --- vgamepad stubs (mobile only) ---

namespace vgamepad {
void setEditMode(bool editing) { (void)editing; }
}

// --- hostfs::saveScreenshot stub ---

namespace hostfs {
void saveScreenshot(const std::string& name, const std::vector<u8>& data) {
    (void)name; (void)data;
}
}

// --- darw_printf ---

int darw_printf(const char* text, ...) {
    va_list args;
    va_start(args, text);
    int ret = vprintf(text, args);
    va_end(args);
    return ret;
}

// --- serialModem stubs ---

void serialModemInit() {}
void serialModemTerm() {}

// --- os_PrecomposedString ---

std::string os_PrecomposedString(std::string str) {
    return str;
}

// --- GGPO netplay stubs ---

#include "network/ggpo.h"
#include "hw/maple/maple_cfg.h"
#include "input/gamepad_device.h"
#include <future>

namespace ggpo {

bool inRollback = false;

std::future<bool> startNetwork() {
    std::promise<bool> p;
    p.set_value(false);
    return p.get_future();
}

void startSession(int localPort, int localPlayerNum) { (void)localPort; (void)localPlayerNum; }
void stopSession() {}

void getInput(MapleInputState inputState[4]) {
    os_UpdateInputState();
    for (int player = 0; player < 4; player++) {
        MapleInputState& state = inputState[player];
        state.kcode = kcode[player];
        state.halfAxes[PJTI_L] = lt[player];
        state.halfAxes[PJTI_R] = rt[player];
        state.halfAxes[PJTI_L2] = lt2[player];
        state.halfAxes[PJTI_R2] = rt2[player];
        state.fullAxes[PJAI_X1] = joyx[player];
        state.fullAxes[PJAI_Y1] = joyy[player];
        state.fullAxes[PJAI_X2] = joyrx[player];
        state.fullAxes[PJAI_Y2] = joyry[player];
        state.fullAxes[PJAI_X3] = joy3x[player];
        state.fullAxes[PJAI_Y3] = joy3y[player];
    }
}

bool nextFrame() { return false; }
bool active() { return false; }
void displayStats() {}
void endOfFrame() {}
void sendChatMessage(int playerNum, const std::string& msg) { (void)playerNum; (void)msg; }
void receiveChatMessages(void (*callback)(int, const std::string&)) { (void)callback; }

}

// --- i18n::getCurrentLocale for macOS ---

namespace i18n {
std::string getCurrentLocale() {
    return "en";
}
}
