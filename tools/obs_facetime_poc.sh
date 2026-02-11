#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
PROTONECTSR_BIN="${BUILD_DIR}/bin/ProtonectSR"
STATUS_BIN="${BUILD_DIR}/bin/KinectStatus"
RTSP_BRIDGE_PY="${ROOT_DIR}/tools/streamer_recorder/udp_rtsp_h264_bridge.py"
MJPEG_BRIDGE_PY="${ROOT_DIR}/tools/streamer_recorder/udp_mjpeg_bridge.py"

MODE="${STREAM_MODE:-rtsp}" # rtsp | mjpeg

UDP_PORT="${UDP_PORT:-10000}"
PRECHECK_STATUS="${PRECHECK_STATUS:-0}"
LIBFREENECT2_DISABLE_RESET="${LIBFREENECT2_DISABLE_RESET:-1}"

# RTSP mode settings
RTSP_HOST="${RTSP_HOST:-127.0.0.1}"
RTSP_PORT="${RTSP_PORT:-8554}"
RTSP_PATH_NAME="${RTSP_PATH_NAME:-kinect}"
RTSP_URL="${RTSP_URL:-rtsp://${RTSP_HOST}:${RTSP_PORT}/${RTSP_PATH_NAME}}"
RTP_ENCODER="${RTP_ENCODER:-h264_videotoolbox}"
RTSP_TRANSPORT="${RTSP_TRANSPORT:-tcp}"
GOP_SIZE="${GOP_SIZE:-15}"
VIDEO_BITRATE="${VIDEO_BITRATE:-8M}"
X264_PRESET="${X264_PRESET:-ultrafast}"
RTSP_BRIDGE_LOG="${BUILD_DIR}/udp_rtsp_h264_bridge.log"
MEDIAMTX_LOG="${BUILD_DIR}/mediamtx.log"
MEDIAMTX_CONFIG="${BUILD_DIR}/mediamtx.yml"
MEDIAMTX_BIN="${MEDIAMTX_BIN:-$(command -v mediamtx || true)}"

# MJPEG mode settings
MJPEG_HOST="${MJPEG_HOST:-127.0.0.1}"
MJPEG_PORT="${MJPEG_PORT:-18080}"
MJPEG_URL="${MJPEG_URL:-http://${MJPEG_HOST}:${MJPEG_PORT}/}"
MJPEG_BRIDGE_LOG="${BUILD_DIR}/udp_mjpeg_bridge.log"

PROTONECT_ARGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--mode rtsp|mjpeg] [ProtonectSR args...]

Modes:
  rtsp   (default) UDP -> H.264 -> RTSP (mediamtx required)
  mjpeg           UDP -> MJPEG HTTP

Examples:
  $(basename "$0")
  $(basename "$0") --mode mjpeg
  STREAM_MODE=mjpeg $(basename "$0")
  RTP_ENCODER=libx264 X264_PRESET=ultrafast $(basename "$0") --mode rtsp
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --mode"
        usage
        exit 1
      fi
      MODE="$2"
      shift 2
      ;;
    --mode=*)
      MODE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      PROTONECT_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "${MODE}" != "rtsp" && "${MODE}" != "mjpeg" ]]; then
  echo "Invalid mode: ${MODE}"
  usage
  exit 1
fi

if [[ ! -x "${PROTONECTSR_BIN}" ]]; then
  echo "Missing ${PROTONECTSR_BIN}"
  echo "Build first:"
  echo "  cmake -S . -B build -DBUILD_STREAMER_RECORDER=ON"
  echo "  cmake --build build --target ProtonectSR -j8"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required."
  exit 1
fi

if [[ "${MODE}" == "rtsp" ]]; then
  if [[ ! -f "${RTSP_BRIDGE_PY}" ]]; then
    echo "Missing ${RTSP_BRIDGE_PY}"
    exit 1
  fi
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is required for RTSP mode."
    exit 1
  fi
  if [[ -z "${MEDIAMTX_BIN}" ]]; then
    echo "mediamtx is required for RTSP mode."
    echo "Install with: brew install mediamtx"
    exit 1
  fi
else
  if [[ ! -f "${MJPEG_BRIDGE_PY}" ]]; then
    echo "Missing ${MJPEG_BRIDGE_PY}"
    exit 1
  fi
fi

graceful_stop() {
  local pid="$1"
  local name="$2"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    return 0
  fi

  kill -INT "${pid}" >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done

  echo "${name} did not exit on SIGINT; sending SIGTERM..."
  kill -TERM "${pid}" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done

  echo "${name} still running; sending SIGKILL."
  kill -KILL "${pid}" >/dev/null 2>&1 || true
}

cleanup() {
  graceful_stop "${SR_PID:-}" "ProtonectSR"
  graceful_stop "${BRIDGE_PID:-}" "Bridge"
  graceful_stop "${MEDIAMTX_PID:-}" "MediaMTX"
  wait "${SR_PID:-}" >/dev/null 2>&1 || true
  wait "${BRIDGE_PID:-}" >/dev/null 2>&1 || true
  wait "${MEDIAMTX_PID:-}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP

MODE_LABEL="$(printf '%s' "${MODE}" | tr '[:lower:]' '[:upper:]')"
echo "=== Kinect -> ProtonectSR UDP -> ${MODE_LABEL} -> OBS -> FaceTime PoC ==="
echo "Mode: ${MODE}"
if [[ "${MODE}" == "rtsp" ]]; then
  echo "1) Open OBS and create a Scene named 'Kinect'."
  echo "2) Add Source: Media Source."
  echo "3) Uncheck 'Local File' and set input URL: ${RTSP_URL}"
  echo "4) If source does not play, disable/enable the source after stream starts."
  echo "5) Click 'Start Virtual Camera' in OBS."
  echo "6) Open FaceTime -> Video -> Camera -> select 'OBS Virtual Camera'."
  echo "Tip) In OBS Media Source, set Buffering to minimum if available."
else
  echo "1) Open OBS and create a Scene named 'Kinect'."
  echo "2) Add Source: Browser."
  echo "3) URL: ${MJPEG_URL}"
  echo "4) Width=1920 Height=1080 FPS=30."
  echo "5) Click 'Start Virtual Camera' in OBS."
  echo "6) Open FaceTime -> Video -> Camera -> select 'OBS Virtual Camera'."
fi
echo

if [[ "${PRECHECK_STATUS}" == "1" ]]; then
  if [[ ! -x "${STATUS_BIN}" ]]; then
    echo "Missing ${STATUS_BIN}"
    echo "Build first: cmake --build build --target KinectStatus -j8"
    exit 1
  fi
  echo "Running KinectStatus precheck for 2 seconds..."
  "${STATUS_BIN}" -seconds 2 || true
fi

if [[ "${MODE}" == "rtsp" ]]; then
  cat > "${MEDIAMTX_CONFIG}" <<EOF
logLevel: warn
rtspAddress: :${RTSP_PORT}
paths:
  ${RTSP_PATH_NAME}:
    source: publisher
EOF

  echo "Starting MediaMTX RTSP server..."
  "${MEDIAMTX_BIN}" "${MEDIAMTX_CONFIG}" >"${MEDIAMTX_LOG}" 2>&1 &
  MEDIAMTX_PID=$!
  sleep 0.5
  if ! kill -0 "${MEDIAMTX_PID}" >/dev/null 2>&1; then
    echo "MediaMTX failed to start. Check log: ${MEDIAMTX_LOG}"
    tail -n 80 "${MEDIAMTX_LOG}" 2>/dev/null || true
    exit 1
  fi

  echo "Starting UDP->RTSP bridge..."
  python3 -u "${RTSP_BRIDGE_PY}" \
    --udp-port "${UDP_PORT}" \
    --rtsp-url "${RTSP_URL}" \
    --encoder "${RTP_ENCODER}" \
    --rtsp-transport "${RTSP_TRANSPORT}" \
    --gop "${GOP_SIZE}" \
    --video-bitrate "${VIDEO_BITRATE}" \
    --x264-preset "${X264_PRESET}" \
    >"${RTSP_BRIDGE_LOG}" 2>&1 &
  BRIDGE_PID=$!
else
  echo "Starting UDP->MJPEG bridge..."
  python3 -u "${MJPEG_BRIDGE_PY}" \
    --bind "${MJPEG_HOST}" \
    --udp-port "${UDP_PORT}" \
    --http-port "${MJPEG_PORT}" \
    >"${MJPEG_BRIDGE_LOG}" 2>&1 &
  BRIDGE_PID=$!
fi

echo "Starting ProtonectSR streamer (RGB only, no viewer)."
echo "Press Ctrl-C to stop."
export LIBFREENECT2_DISABLE_RESET
if [[ ${#PROTONECT_ARGS[@]} -gt 0 ]]; then
  "${PROTONECTSR_BIN}" -streamer -nodepth -noviewer "${PROTONECT_ARGS[@]}" &
else
  "${PROTONECTSR_BIN}" -streamer -nodepth -noviewer &
fi
SR_PID=$!

echo "Waiting for stream readiness..."
READY=0
for _ in $(seq 1 120); do
  if [[ "${MODE}" == "rtsp" ]]; then
    if [[ -s "${RTSP_BRIDGE_LOG}" ]] && grep -q "frames=" "${RTSP_BRIDGE_LOG}"; then
      READY=1
      echo "RTSP stream is active: ${RTSP_URL}"
      break
    fi
  else
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS "${MJPEG_URL}health" >/dev/null 2>&1; then
        READY=1
        echo "MJPEG stream is active: ${MJPEG_URL}"
        break
      fi
    else
      if python3 -c "import urllib.request; urllib.request.urlopen('${MJPEG_URL}health', timeout=0.3)" >/dev/null 2>&1; then
        READY=1
        echo "MJPEG stream is active: ${MJPEG_URL}"
        break
      fi
    fi
  fi

  if [[ "${MODE}" == "rtsp" ]] && ! kill -0 "${MEDIAMTX_PID}" >/dev/null 2>&1; then
    echo "MediaMTX exited unexpectedly. Check log: ${MEDIAMTX_LOG}"
    tail -n 80 "${MEDIAMTX_LOG}" 2>/dev/null || true
    exit 1
  fi
  if ! kill -0 "${BRIDGE_PID}" >/dev/null 2>&1; then
    echo "Bridge exited unexpectedly."
    if [[ "${MODE}" == "rtsp" ]]; then
      echo "Bridge log: ${RTSP_BRIDGE_LOG}"
      tail -n 80 "${RTSP_BRIDGE_LOG}" 2>/dev/null || true
    else
      echo "Bridge log: ${MJPEG_BRIDGE_LOG}"
      tail -n 80 "${MJPEG_BRIDGE_LOG}" 2>/dev/null || true
    fi
    exit 1
  fi
  if ! kill -0 "${SR_PID}" >/dev/null 2>&1; then
    echo "ProtonectSR exited before stream was ready."
    exit 1
  fi
  sleep 0.25
done

if [[ "${READY}" != "1" ]]; then
  echo "Stream was not ready in time."
  if [[ "${MODE}" == "rtsp" ]]; then
    echo "Bridge log: ${RTSP_BRIDGE_LOG}"
    tail -n 120 "${RTSP_BRIDGE_LOG}" 2>/dev/null || true
    echo "MediaMTX log: ${MEDIAMTX_LOG}"
    tail -n 120 "${MEDIAMTX_LOG}" 2>/dev/null || true
  else
    echo "Bridge log: ${MJPEG_BRIDGE_LOG}"
    tail -n 120 "${MJPEG_BRIDGE_LOG}" 2>/dev/null || true
  fi
  exit 1
fi

wait "${SR_PID}"
