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
  // Mix ~5 ms of audio at a time (48000 * 0.005 = 240 stereo frames)
  constexpr std::size_t FRAMES_PER_CHUNK = 240;
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

    // Sleep ~5 ms to roughly match real-time audio rate without busy-waiting
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
}
