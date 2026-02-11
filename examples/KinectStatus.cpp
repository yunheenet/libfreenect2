/*
 * This file is part of the OpenKinect Project. http://www.openkinect.org
 *
 * Copyright (c) 2026 individual OpenKinect contributors.
 *
 * This code is licensed to you under the terms of the Apache License, version
 * 2.0, or, at your option, the terms of the GNU General Public License,
 * version 2.0. See the APACHE20 and GPL2 files for the text of the licenses.
 */

#include <csignal>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>
#include <chrono>

#include <libfreenect2/libfreenect2.hpp>
#include <libfreenect2/frame_listener_impl.h>
#include <libfreenect2/logger.h>
#include <libfreenect2/packet_pipeline.h>

#ifdef __APPLE__
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#endif

volatile sig_atomic_t kinect_status_shutdown = 0;

void sigint_handler(int)
{
  kinect_status_shutdown = 1;
}

bool containsCaseInsensitive(const std::string &text, const std::string &pattern)
{
  if (pattern.empty())
  {
    return true;
  }

  for (size_t i = 0; i + pattern.size() <= text.size(); ++i)
  {
    bool match = true;
    for (size_t j = 0; j < pattern.size(); ++j)
    {
      const unsigned char tc = static_cast<unsigned char>(text[i + j]);
      const unsigned char pc = static_cast<unsigned char>(pattern[j]);
      if (std::tolower(tc) != std::tolower(pc))
      {
        match = false;
        break;
      }
    }
    if (match)
    {
      return true;
    }
  }

  return false;
}

struct MicStatus
{
  bool probe_supported;
  bool present;
  bool in_use;
  std::string name;
  std::string detail;
};

#ifdef __APPLE__
AudioObjectPropertyElement audioObjectPropertyElementMain()
{
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && (__MAC_OS_X_VERSION_MAX_ALLOWED >= 120000)
  return kAudioObjectPropertyElementMain;
#else
  return kAudioObjectPropertyElementMaster;
#endif
}

std::string cfStringToStdString(CFStringRef value)
{
  if (value == NULL)
  {
    return "";
  }

  const char *direct = CFStringGetCStringPtr(value, kCFStringEncodingUTF8);
  if (direct != NULL)
  {
    return std::string(direct);
  }

  CFIndex length = CFStringGetLength(value);
  CFIndex max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
  std::vector<char> buffer(static_cast<size_t>(max_size), '\0');
  if (!CFStringGetCString(value, &buffer[0], max_size, kCFStringEncodingUTF8))
  {
    return "";
  }
  return std::string(&buffer[0]);
}

std::string getAudioDeviceString(AudioDeviceID device_id, AudioObjectPropertySelector selector)
{
  AudioObjectPropertyAddress address;
  address.mSelector = selector;
  address.mScope = kAudioObjectPropertyScopeGlobal;
  address.mElement = audioObjectPropertyElementMain();

  CFStringRef value = NULL;
  UInt32 size = sizeof(value);
  OSStatus status = AudioObjectGetPropertyData(device_id, &address, 0, NULL, &size, &value);
  if (status != noErr || value == NULL)
  {
    return "";
  }

  std::string result = cfStringToStdString(value);
  CFRelease(value);
  return result;
}

bool hasInputChannels(AudioDeviceID device_id)
{
  AudioObjectPropertyAddress address;
  address.mSelector = kAudioDevicePropertyStreamConfiguration;
  address.mScope = kAudioDevicePropertyScopeInput;
  address.mElement = audioObjectPropertyElementMain();

  UInt32 data_size = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(device_id, &address, 0, NULL, &data_size);
  if (status != noErr || data_size == 0)
  {
    return false;
  }

  std::vector<unsigned char> storage(data_size, 0);
  AudioBufferList *buffers = reinterpret_cast<AudioBufferList *>(&storage[0]);
  status = AudioObjectGetPropertyData(device_id, &address, 0, NULL, &data_size, buffers);
  if (status != noErr)
  {
    return false;
  }

  UInt32 total_channels = 0;
  for (UInt32 idx = 0; idx < buffers->mNumberBuffers; ++idx)
  {
    total_channels += buffers->mBuffers[idx].mNumberChannels;
  }
  return total_channels > 0;
}

bool isDeviceRunning(AudioDeviceID device_id)
{
  AudioObjectPropertyAddress address;
  address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere;
  address.mScope = kAudioObjectPropertyScopeGlobal;
  address.mElement = audioObjectPropertyElementMain();

  UInt32 running = 0;
  UInt32 size = sizeof(running);
  OSStatus status = AudioObjectGetPropertyData(device_id, &address, 0, NULL, &size, &running);
  if (status != noErr)
  {
    return false;
  }
  return running != 0;
}

MicStatus queryKinectMicStatus()
{
  MicStatus info;
  info.probe_supported = true;
  info.present = false;
  info.in_use = false;

  AudioObjectPropertyAddress address;
  address.mSelector = kAudioHardwarePropertyDevices;
  address.mScope = kAudioObjectPropertyScopeGlobal;
  address.mElement = audioObjectPropertyElementMain();

  UInt32 data_size = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &data_size);
  if (status != noErr || data_size == 0)
  {
    info.detail = "failed to enumerate CoreAudio devices";
    return info;
  }

  const UInt32 count = data_size / sizeof(AudioDeviceID);
  std::vector<AudioDeviceID> device_ids(count, kAudioDeviceUnknown);
  status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &data_size, &device_ids[0]);
  if (status != noErr)
  {
    info.detail = "failed to read CoreAudio device list";
    return info;
  }

  for (UInt32 idx = 0; idx < count; ++idx)
  {
    AudioDeviceID device_id = device_ids[idx];
    if (device_id == kAudioDeviceUnknown)
    {
      continue;
    }

    if (!hasInputChannels(device_id))
    {
      continue;
    }

    const std::string name = getAudioDeviceString(device_id, kAudioObjectPropertyName);
    const std::string manufacturer = getAudioDeviceString(device_id, kAudioObjectPropertyManufacturer);
    const std::string uid = getAudioDeviceString(device_id, kAudioDevicePropertyDeviceUID);

    const bool looks_like_kinect =
      containsCaseInsensitive(name, "kinect") ||
      containsCaseInsensitive(name, "xbox nui") ||
      containsCaseInsensitive(manufacturer, "kinect") ||
      containsCaseInsensitive(uid, "kinect") ||
      containsCaseInsensitive(uid, "xbox nui");

    if (!looks_like_kinect)
    {
      continue;
    }

    info.present = true;
    info.name = name.empty() ? "Unnamed Kinect audio device" : name;
    if (isDeviceRunning(device_id))
    {
      info.in_use = true;
    }
  }

  if (!info.present)
  {
    info.detail = "no Kinect-like input device detected in CoreAudio";
  }

  return info;
}
#else
MicStatus queryKinectMicStatus()
{
  MicStatus info;
  info.probe_supported = false;
  info.present = false;
  info.in_use = false;
  info.detail = "microphone probing is only implemented for macOS in this tool";
  return info;
}
#endif

void printUsage(const char *program)
{
  std::cerr << "Usage: " << program << " [-serial <device serial>] [-seconds <N>]" << std::endl;
  std::cerr << "  -seconds 0 means run until Ctrl-C (default)." << std::endl;
}

int main(int argc, char *argv[])
{
  std::string serial;
  int run_seconds = 0;

  for (int i = 1; i < argc; ++i)
  {
    const std::string arg(argv[i]);
    if (arg == "-serial")
    {
      if (i + 1 >= argc)
      {
        printUsage(argv[0]);
        return -1;
      }
      serial = argv[++i];
    }
    else if (arg == "-seconds")
    {
      if (i + 1 >= argc)
      {
        printUsage(argv[0]);
        return -1;
      }
      run_seconds = std::atoi(argv[++i]);
      if (run_seconds < 0)
      {
        std::cerr << "-seconds must be >= 0" << std::endl;
        return -1;
      }
    }
    else if (arg == "-h" || arg == "--help" || arg == "-help")
    {
      printUsage(argv[0]);
      return 0;
    }
    else
    {
      std::cerr << "Unknown argument: " << arg << std::endl;
      printUsage(argv[0]);
      return -1;
    }
  }

  signal(SIGINT, sigint_handler);

  libfreenect2::setGlobalLogger(libfreenect2::createConsoleLogger(libfreenect2::Logger::Info));

  libfreenect2::Freenect2 freenect2;
  if (freenect2.enumerateDevices() == 0)
  {
    std::cerr << "Kinect status: no device connected." << std::endl;
    return -1;
  }

  if (serial.empty())
  {
    serial = freenect2.getDefaultDeviceSerialNumber();
  }

  libfreenect2::Freenect2Device *dev = freenect2.openDevice(serial);
  if (dev == 0)
  {
    std::cerr << "Kinect status: failed to open device " << serial << std::endl;
    return -1;
  }

  libfreenect2::SyncMultiFrameListener listener(libfreenect2::Frame::Color);
  libfreenect2::FrameMap frames;
  dev->setColorFrameListener(&listener);

  if (!dev->startStreams(true, false))
  {
    std::cerr << "Kinect status: failed to start RGB stream." << std::endl;
    dev->close();
    return -1;
  }

  std::cout << "Device serial: " << dev->getSerialNumber() << std::endl;
  std::cout << "Device firmware: " << dev->getFirmwareVersion() << std::endl;

  std::chrono::steady_clock::time_point started_at = std::chrono::steady_clock::now();
  std::chrono::steady_clock::time_point last_report = started_at;
  std::chrono::steady_clock::time_point last_color_frame;
  size_t total_frames = 0;
  size_t frames_since_last_report = 0;

  while (!kinect_status_shutdown)
  {
    if (run_seconds > 0)
    {
      const long long elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - started_at).count();
      if (elapsed >= run_seconds)
      {
        break;
      }
    }

    if (listener.waitForNewFrame(frames, 1000))
    {
      ++total_frames;
      ++frames_since_last_report;
      last_color_frame = std::chrono::steady_clock::now();
      listener.release(frames);
    }

    const std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now();
    const long long report_elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_report).count();
    if (report_elapsed_ms < 1000)
    {
      continue;
    }

    const double fps = (report_elapsed_ms > 0)
      ? static_cast<double>(frames_since_last_report) * 1000.0 / static_cast<double>(report_elapsed_ms)
      : 0.0;

    const bool color_active = (last_color_frame.time_since_epoch().count() != 0) &&
      (std::chrono::duration_cast<std::chrono::seconds>(now - last_color_frame).count() < 2);

    const MicStatus mic = queryKinectMicStatus();

    std::cout << "[status] color=" << (color_active ? "ACTIVE" : "INACTIVE")
              << " fps=" << std::fixed << std::setprecision(1) << fps
              << " total_frames=" << total_frames;

    if (mic.probe_supported)
    {
      if (mic.present)
      {
        std::cout << " mic=" << (mic.in_use ? "IN_USE" : "IDLE")
                  << " mic_name=\"" << mic.name << "\"";
      }
      else
      {
        std::cout << " mic=NOT_FOUND";
        if (!mic.detail.empty())
        {
          std::cout << " mic_detail=\"" << mic.detail << "\"";
        }
      }
    }
    else
    {
      std::cout << " mic=UNSUPPORTED";
      if (!mic.detail.empty())
      {
        std::cout << " mic_detail=\"" << mic.detail << "\"";
      }
    }

    std::cout << std::endl;

    frames_since_last_report = 0;
    last_report = now;
  }

  dev->stop();
  dev->close();
  return 0;
}
