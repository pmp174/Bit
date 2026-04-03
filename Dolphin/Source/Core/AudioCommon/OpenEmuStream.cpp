// Copyright 2025 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "AudioCommon/OpenEmuStream.h"

#include <chrono>

std::mutex OpenEmuStream::s_callback_mutex;
OpenEmuAudioCallback OpenEmuStream::s_audio_callback;

bool OpenEmuStream::Init()
{
  return true;
}

bool OpenEmuStream::SetRunning(bool running)
{
  if (running && !m_running.load())
  {
    m_running.store(true);
    m_thread = std::thread(&OpenEmuStream::AudioThread, this);
  }
  else if (!running && m_running.load())
  {
    m_running.store(false);
    if (m_thread.joinable())
      m_thread.join();
  }
  return true;
}

void OpenEmuStream::SetVolume(int volume)
{
}

void OpenEmuStream::SetAudioCallback(OpenEmuAudioCallback callback)
{
  std::lock_guard<std::mutex> lock(s_callback_mutex);
  s_audio_callback = std::move(callback);
}

void OpenEmuStream::ClearAudioCallback()
{
  std::lock_guard<std::mutex> lock(s_callback_mutex);
  s_audio_callback = nullptr;
}

void OpenEmuStream::AudioThread()
{
  // Mix ~10 ms of audio at a time (48000 * 0.010 = 480 stereo frames).
  // Using a larger chunk than the sleep interval ensures the ring buffer
  // stays ahead of the consumer even when the OS overshoots the sleep.
  constexpr std::size_t FRAMES_PER_CHUNK = 480;
  s16 buffer[FRAMES_PER_CHUNK * 2]; // stereo interleaved

  while (m_running.load())
  {
    std::size_t mixed = m_mixer->Mix(buffer, FRAMES_PER_CHUNK);

    if (mixed > 0)
    {
      std::lock_guard<std::mutex> lock(s_callback_mutex);
      if (s_audio_callback)
      {
        // Each stereo frame is 2 samples * 2 bytes = 4 bytes
        s_audio_callback(buffer, static_cast<u32>(mixed * 4));
      }
    }

    // Sleep less than the chunk duration so we consistently produce audio
    // faster than the consumer drains it. The ring buffer absorbs the
    // surplus and the shorter sleep reduces the impact of OS scheduling
    // jitter that causes underruns (crackling/popping).
    std::this_thread::sleep_for(std::chrono::milliseconds(3));
  }
}
