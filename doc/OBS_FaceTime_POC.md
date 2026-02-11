# Kinect v2 -> FaceTime PoC (Dual Mode: RTSP / MJPEG)

`tools/obs_facetime_poc.sh` now supports two output modes:

1. `rtsp` (default): lower bandwidth, typically higher latency
2. `mjpeg`: easier path, often lower latency on local machine, higher bandwidth

## Build

```bash
cd /Users/yuni/Dev/libfreenect2
cmake -S . -B build -DBUILD_STREAMER_RECORDER=ON
cmake --build build --target ProtonectSR KinectStatus -j8
```

## Prerequisites

RTSP mode:

```bash
brew install ffmpeg mediamtx
```

MJPEG mode:

```bash
brew install ffmpeg
```

## Run

RTSP mode (default):

```bash
cd /Users/yuni/Dev/libfreenect2
./tools/obs_facetime_poc.sh
```

MJPEG mode:

```bash
cd /Users/yuni/Dev/libfreenect2
./tools/obs_facetime_poc.sh --mode mjpeg
```

Optional precheck:

```bash
PRECHECK_STATUS=1 ./tools/obs_facetime_poc.sh --mode rtsp
```

## OBS setup

RTSP mode:

1. Add `Media Source`.
2. Uncheck `Local File`.
3. URL: `rtsp://127.0.0.1:8554/kinect`
4. If source appears idle, disable/enable source once.
5. If buffering option exists, set minimum.

MJPEG mode:

1. Add `Browser` source.
2. URL: `http://127.0.0.1:18080/`
3. Width `1920`, Height `1080`, FPS `30`.

## FaceTime setup

1. Open FaceTime.
2. `Video` menu.
3. Camera: `OBS Virtual Camera`.

## Useful env overrides

RTSP low-latency profile:

```bash
RTP_ENCODER=libx264 X264_PRESET=ultrafast GOP_SIZE=10 VIDEO_BITRATE=10M RTSP_TRANSPORT=tcp ./tools/obs_facetime_poc.sh --mode rtsp
```

MJPEG port override:

```bash
MJPEG_PORT=18081 ./tools/obs_facetime_poc.sh --mode mjpeg
```

Common:

- `LIBFREENECT2_DISABLE_RESET=1` is default in script
- Graceful shutdown on `Ctrl-C` / terminal close (`SIGINT -> SIGTERM -> SIGKILL`)
