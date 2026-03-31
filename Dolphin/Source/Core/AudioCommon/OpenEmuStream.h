// Copyright 2025 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <atomic>
#include <functional>
#include <mutex>
#include <thread>

#include "AudioCommon/SoundStream.h"

#define BACKEND_OPENEMU "OpenEmu"

// Callback type: receives interleaved stereo s16 samples and a byte count.
using OpenEmuAudioCallback = std::function<void(const s16*, u32)>;

// Sound stream that mixes Dolphin audio on a background thread and delivers
// it via a registered callback.  Designed for OpenEmu integration where
// the host provides its own audio output through a ring buffer.
class OpenEmuStream final : public SoundStream
{
public:
  bool Init() override;
  bool SetRunning(bool running) override;
  void SetVolume(int volume) override;

  static bool IsValid() { return true; }

  // Register / clear the audio callback.  Thread-safe.
  static void SetAudioCallback(OpenEmuAudioCallback callback);
  static void ClearAudioCallback();

private:
  void AudioThread();

  std::thread m_thread;
  std::atomic<bool> m_running{false};

  static std::mutex s_callback_mutex;
  static OpenEmuAudioCallback s_audio_callback;
};
