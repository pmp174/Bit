// Copyright (c) 2025, OpenEmu Team
// Stubs for symbols that are not available in the OpenEmu integration.
// These provide link-time resolution for code paths that won't be hit at runtime.

#include "common/Pcsx2Defs.h"
#include "common/Error.h"
#include "common/HTTPDownloader.h"
#include "pcsx2/Host/AudioStream.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>
#include <thread>
#include <atomic>
#include <algorithm>
#include <cstdint>

// Forward declaration of the audio write callback (defined in PCSX2GameCore.mm)
namespace OpenEmuBridge {
    typedef void (*AudioWriteFunc)(const int16_t* samples, uint32_t num_frames);
    extern AudioWriteFunc g_audioWriteFunc;
}

// ============================================================================
// OpenEmuAudioStream - drains PCSX2's internal audio buffer to OpenEmu's ring buffer
// ============================================================================

class OpenEmuAudioStream : public AudioStream
{
public:
    OpenEmuAudioStream(u32 sample_rate, const AudioStreamParameters& parameters)
        : AudioStream(sample_rate, parameters) {}

    ~OpenEmuAudioStream() override
    {
        // Stop drain thread BEFORE base class destructor frees the ring buffer
        m_running = false;
        if (m_drain_thread.joinable())
            m_drain_thread.join();
    }

    void SetPaused(bool paused) override
    {
        AudioStream::SetPaused(paused);
    }

    bool Initialize(bool stretch_enabled)
    {
        BaseInitialize(&StereoSampleReaderImpl, stretch_enabled);
        m_running = true;
        m_drain_thread = std::thread(&OpenEmuAudioStream::DrainThread, this);
        return true;
    }

private:
    void DrainThread()
    {
        // Drain at a steady rate matching the hardware sample rate.
        // This mimics how Cubeb/CoreAudio callbacks request data at regular intervals.
        // Use short intervals (5ms) with small chunks for smoother output and less jitter.
        // ReadFrames handles underruns internally (resamples or fills silence).
        constexpr u32 DRAIN_INTERVAL_MS = 5;
        const u32 frames_per_drain = (m_sample_rate * DRAIN_INTERVAL_MS) / 1000;  // 240 frames at 48kHz
        const u32 buf_samples = frames_per_drain * NUM_INPUT_CHANNELS;

        auto float_buf = std::make_unique<float[]>(buf_samples);
        auto int16_buf = std::make_unique<int16_t[]>(buf_samples);

        // Let the buffer fill a bit before starting to drain (reduces initial underruns)
        std::this_thread::sleep_for(std::chrono::milliseconds(50));

        while (m_running)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(DRAIN_INTERVAL_MS));

            if (m_paused || !OpenEmuBridge::g_audioWriteFunc)
                continue;

            // Always read exactly frames_per_drain frames to maintain steady output.
            // ReadFrames handles underruns by resampling available data to fill the request.
            ReadFrames(float_buf.get(), frames_per_drain);

            // Convert float [-1.0, 1.0] to int16
            for (u32 i = 0; i < buf_samples; i++)
            {
                float s = float_buf[i] * 32767.0f;
                if (s > 32767.0f) s = 32767.0f;
                if (s < -32768.0f) s = -32768.0f;
                int16_buf[i] = static_cast<int16_t>(s);
            }

            OpenEmuBridge::g_audioWriteFunc(int16_buf.get(), frames_per_drain);
        }
    }

    std::thread m_drain_thread;
    std::atomic<bool> m_running{false};
};

// ============================================================================
// AudioStream backend stubs
// ============================================================================

std::vector<std::pair<std::string, std::string>> AudioStream::GetCubebDriverNames()
{
    return {};
}

std::vector<AudioStream::DeviceInfo> AudioStream::GetCubebOutputDevices(const char* driver)
{
    return {};
}

std::unique_ptr<AudioStream> AudioStream::CreateCubebAudioStream(u32 sample_rate,
    const AudioStreamParameters& parameters, const char* driver_name,
    const char* device_name, bool stretch_enabled, Error* error)
{
    // Return our custom OpenEmu audio stream that drains to OERingBuffer
    auto stream = std::make_unique<OpenEmuAudioStream>(sample_rate, parameters);
    if (!stream->Initialize(stretch_enabled))
    {
        Error::SetStringView(error, "Failed to initialize OpenEmu audio stream");
        return nullptr;
    }
    return stream;
}

std::unique_ptr<AudioStream> AudioStream::CreateSDLAudioStream(u32 sample_rate,
    const AudioStreamParameters& parameters, bool stretch_enabled, Error* error)
{
    Error::SetStringView(error, "SDL audio not available in OpenEmu build");
    return nullptr;
}

// ============================================================================
// HTTPDownloader stub (WinHTTP/Curl excluded)
// ============================================================================

std::unique_ptr<HTTPDownloader> HTTPDownloader::Create(std::string user_agent)
{
    return nullptr;
}

// ============================================================================
// Demangler stubs (demangler library excluded due to C compatibility issues)
// ============================================================================

extern "C" {

char* cplus_demangle(const char* mangled, int options)
{
    return nullptr;
}

int cplus_demangle_opname(const char* opname, char* result, int options)
{
    return 0;
}

} // extern "C"

// ============================================================================
// ImGuiFreeType stub (freetype/plutosvg not linked)
// ============================================================================

struct ImFontLoader;

namespace ImGuiFreeType {
    const ImFontLoader* GetFontLoader() { return nullptr; }
}
