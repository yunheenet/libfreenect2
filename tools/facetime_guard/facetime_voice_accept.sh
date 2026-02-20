#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="${ROOT_DIR}/tools/facetime_guard/build_facetime_guard.sh"
BIN="${ROOT_DIR}/build/bin/facetime_guard"

KEYWORD="${KEYWORD:-전화받아}"
SHORTCUT_NAME="${SHORTCUT_NAME:-GamjaListenKeyword}"
STT_BACKEND="${STT_BACKEND:-shortcuts}"
POLL_SECONDS="${POLL_SECONDS:-0.7}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-8}"
ENABLE_TTS="${ENABLE_TTS:-1}"
TTS_ASYNC="${TTS_ASYNC:-1}"
VLLM_BASE_URL="${VLLM_BASE_URL:-http://127.0.0.1:8000}"
VLLM_STT_PROFILE="${VLLM_STT_PROFILE:-ko-fast}"
VLLM_STT_MODEL="${VLLM_STT_MODEL:-}"
VLLM_STT_LANGUAGE="${VLLM_STT_LANGUAGE:-}"
VLLM_CAPTURE_SECONDS="${VLLM_CAPTURE_SECONDS:-2.5}"
VLLM_AUDIO_DEVICE="${VLLM_AUDIO_DEVICE:-0}"
VLLM_HTTP_TIMEOUT_SECONDS="${VLLM_HTTP_TIMEOUT_SECONDS:-25}"
ANNOUNCE_TEXT="${ANNOUNCE_TEXT:-영상통화가 왔습니다. 받으시려면 '전화받아'를 말씀해주세요.}"
ANNOUNCE_TEXT_CALLER_TEMPLATE="${ANNOUNCE_TEXT_CALLER_TEMPLATE:-%s에게 영상통화가 왔습니다. 받으시려면 '전화받아'를 말씀해주세요.}"
DETECT_DEBUG="${DETECT_DEBUG:-0}"
RING_CLEAR_IDLE_COUNT="${RING_CLEAR_IDLE_COUNT:-4}"
ATTEMPT_COOLDOWN_SECONDS="${ATTEMPT_COOLDOWN_SECONDS:-4}"
ATTEMPT_COOLDOWN_DURING_TTS_SECONDS="${ATTEMPT_COOLDOWN_DURING_TTS_SECONDS:-1}"
ATTEMPT_COOLDOWN_EMPTY_SECONDS="${ATTEMPT_COOLDOWN_EMPTY_SECONDS:-1}"
SUPPRESS_ANNOUNCE_ECHO="${SUPPRESS_ANNOUNCE_ECHO:-1}"
POST_ACCEPT_HOLDOFF_SECONDS="${POST_ACCEPT_HOLDOFF_SECONDS:-20}"
ACCEPT_VERIFY_TIMEOUT_SECONDS="${ACCEPT_VERIFY_TIMEOUT_SECONDS:-6}"
ACCEPT_VERIFY_POLL_SECONDS="${ACCEPT_VERIFY_POLL_SECONDS:-0.4}"
ACCEPT_VERIFY_CLEAR_COUNT="${ACCEPT_VERIFY_CLEAR_COUNT:-2}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --keyword TEXT       Keyword to detect (default: ${KEYWORD})
  --shortcut NAME      Shortcuts name for dictation (default: ${SHORTCUT_NAME})
  --stt-backend NAME   STT backend: shortcuts|vllm (default: ${STT_BACKEND})
  --stt-profile NAME   STT profile: ko-fast|ko-accurate|ko-lite|en-fast (default: ${VLLM_STT_PROFILE})
  --stt-model NAME     Explicit STT model alias/HF id (overrides --stt-profile)
  --poll SEC           Poll interval in seconds (default: ${POLL_SECONDS})
  --cooldown SEC       Cooldown after one handled event (default: ${COOLDOWN_SECONDS})
  --no-tts             Disable TTS
  -h, --help           Show help

Environment overrides:
  KEYWORD, SHORTCUT_NAME, STT_BACKEND, POLL_SECONDS, COOLDOWN_SECONDS, ENABLE_TTS, ANNOUNCE_TEXT, DETECT_DEBUG,
  TTS_ASYNC, ANNOUNCE_TEXT_CALLER_TEMPLATE, RING_CLEAR_IDLE_COUNT, ATTEMPT_COOLDOWN_SECONDS,
  ATTEMPT_COOLDOWN_DURING_TTS_SECONDS, ATTEMPT_COOLDOWN_EMPTY_SECONDS, SUPPRESS_ANNOUNCE_ECHO,
  POST_ACCEPT_HOLDOFF_SECONDS, ACCEPT_VERIFY_TIMEOUT_SECONDS, ACCEPT_VERIFY_POLL_SECONDS, ACCEPT_VERIFY_CLEAR_COUNT,
  VLLM_BASE_URL, VLLM_STT_PROFILE, VLLM_STT_MODEL, VLLM_STT_LANGUAGE, VLLM_CAPTURE_SECONDS, VLLM_AUDIO_DEVICE,
  VLLM_HTTP_TIMEOUT_SECONDS
USAGE
}

resolve_vllm_stt_model_by_profile() {
  case "$1" in
    ko-accurate)
      printf 'whisper-large-v3'
      ;;
    ko-fast)
      printf 'whisper-large-v3-turbo'
      ;;
    ko-lite)
      printf 'whisper-small'
      ;;
    en-fast)
      printf 'parakeet'
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_vllm_stt_language_by_profile() {
  case "$1" in
    en-fast)
      printf 'en'
      ;;
    ko-fast|ko-accurate|ko-lite)
      printf 'ko'
      ;;
    *)
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keyword)
      KEYWORD="$2"
      shift 2
      ;;
    --shortcut)
      SHORTCUT_NAME="$2"
      shift 2
      ;;
    --stt-backend)
      STT_BACKEND="$2"
      shift 2
      ;;
    --stt-profile)
      VLLM_STT_PROFILE="$2"
      shift 2
      ;;
    --stt-model)
      VLLM_STT_MODEL="$2"
      shift 2
      ;;
    --poll)
      POLL_SECONDS="$2"
      shift 2
      ;;
    --cooldown)
      COOLDOWN_SECONDS="$2"
      shift 2
      ;;
    --no-tts)
      ENABLE_TTS="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${VLLM_STT_MODEL}" ]]; then
  if ! VLLM_STT_MODEL="$(resolve_vllm_stt_model_by_profile "${VLLM_STT_PROFILE}")"; then
    echo "Unsupported VLLM_STT_PROFILE='${VLLM_STT_PROFILE}'"
    echo "Use one of: ko-fast, ko-accurate, ko-lite, en-fast"
    exit 1
  fi
fi

if [[ -z "${VLLM_STT_LANGUAGE}" ]]; then
  if ! VLLM_STT_LANGUAGE="$(resolve_vllm_stt_language_by_profile "${VLLM_STT_PROFILE}")"; then
    echo "Unsupported VLLM_STT_PROFILE='${VLLM_STT_PROFILE}'"
    echo "Use one of: ko-fast, ko-accurate, ko-lite, en-fast"
    exit 1
  fi
fi

case "${STT_BACKEND}" in
  shortcuts)
    if ! command -v shortcuts >/dev/null 2>&1; then
      echo "shortcuts command not found (STT_BACKEND=shortcuts)."
      exit 1
    fi
    ;;
  vllm)
    if ! command -v ffmpeg >/dev/null 2>&1; then
      echo "ffmpeg not found (required for STT_BACKEND=vllm)."
      exit 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
      echo "curl not found (required for STT_BACKEND=vllm)."
      exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo "python3 not found (required for STT_BACKEND=vllm)."
      exit 1
    fi
    ;;
  *)
    echo "Unsupported STT_BACKEND='${STT_BACKEND}' (use shortcuts|vllm)."
    exit 1
    ;;
esac

if [[ ! -x "${BUILD_SCRIPT}" ]]; then
  echo "Missing build script: ${BUILD_SCRIPT}"
  exit 1
fi

if [[ ! -x "${BIN}" ]]; then
  "${BUILD_SCRIPT}"
fi

normalize_text() {
  printf '%s' "$1" | tr -d '[:space:]'
}

contains_keyword() {
  local transcript_norm="$1"
  local keyword_norm="$2"
  [[ -n "${transcript_norm}" && -n "${keyword_norm}" && "${transcript_norm}" == *"${keyword_norm}"* ]]
}

clean_caller() {
  local caller="$1"
  caller="${caller//$'\t'/ }"
  caller="${caller//$'\n'/ }"
  caller="$(printf '%s' "${caller}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  if [[ -z "${caller}" || "${caller}" == "UNKNOWN" ]]; then
    printf ''
    return
  fi
  printf '%s' "${caller}"
}

build_announce_text() {
  local caller="$1"
  if [[ -n "${caller}" ]]; then
    printf "${ANNOUNCE_TEXT_CALLER_TEMPLATE}" "${caller}"
  else
    printf '%s' "${ANNOUNCE_TEXT}"
  fi
}

resolve_avfoundation_input() {
  local dev="${VLLM_AUDIO_DEVICE}"
  if [[ "${dev}" == *":"* ]]; then
    printf '%s' "${dev}"
  else
    printf ':%s' "${dev}"
  fi
}

run_stt_shortcuts() {
  shortcuts run "${SHORTCUT_NAME}" 2>/dev/null
}

run_stt_vllm() {
  local tmp_base wav_file json_file log_file input_spec rc http_code err_msg
  tmp_base="$(mktemp -t facetime_guard_stt)"
  wav_file="${tmp_base}.wav"
  json_file="${tmp_base}.json"
  log_file="${tmp_base}.log"
  input_spec="$(resolve_avfoundation_input)"

  rc=0
  ffmpeg -nostdin -loglevel error -y \
    -f avfoundation -i "${input_spec}" \
    -t "${VLLM_CAPTURE_SECONDS}" \
    -ac 1 -ar 16000 \
    -f wav "${wav_file}" \
    2>"${log_file}" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    if [[ "${DETECT_DEBUG}" == "1" ]]; then
      echo "DEBUG vllm-stt capture failed rc=${rc} device='${input_spec}' sec=${VLLM_CAPTURE_SECONDS}" >&2
      sed -n '1,80p' "${log_file}" >&2 || true
    fi
    rm -f "${wav_file}" "${json_file}" "${log_file}" "${tmp_base}"
    return 1
  fi

  rc=0
  http_code=""
  if [[ -n "${VLLM_STT_LANGUAGE}" ]]; then
    http_code="$(curl -sS --max-time "${VLLM_HTTP_TIMEOUT_SECONDS}" \
      -X POST "${VLLM_BASE_URL%/}/v1/audio/transcriptions" \
      -F "file=@${wav_file};type=audio/wav" \
      -F "model=${VLLM_STT_MODEL}" \
      -F "language=${VLLM_STT_LANGUAGE}" \
      -o "${json_file}" \
      -w "%{http_code}" \
      2>"${log_file}")" || rc=$?
  else
    http_code="$(curl -sS --max-time "${VLLM_HTTP_TIMEOUT_SECONDS}" \
      -X POST "${VLLM_BASE_URL%/}/v1/audio/transcriptions" \
      -F "file=@${wav_file};type=audio/wav" \
      -F "model=${VLLM_STT_MODEL}" \
      -o "${json_file}" \
      -w "%{http_code}" \
      2>"${log_file}")" || rc=$?
  fi

  if [[ ${rc} -ne 0 ]]; then
    if [[ "${DETECT_DEBUG}" == "1" ]]; then
      echo "DEBUG vllm-stt http failed rc=${rc} url='${VLLM_BASE_URL%/}/v1/audio/transcriptions'" >&2
      sed -n '1,80p' "${log_file}" >&2 || true
    fi
    rm -f "${wav_file}" "${json_file}" "${log_file}" "${tmp_base}"
    return 1
  fi

  if [[ "${http_code}" != "200" ]]; then
    err_msg="$(python3 - "${json_file}" <<'PY'
import json
import sys

msg = ""
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        payload = json.load(f)
    if isinstance(payload, dict):
        if isinstance(payload.get("error"), dict):
            detail = payload["error"].get("message")
            if isinstance(detail, str):
                msg = detail
        elif isinstance(payload.get("detail"), str):
            msg = payload["detail"]
except Exception:
    msg = ""
print(msg.strip())
PY
)"
    if [[ -z "${err_msg}" ]]; then
      err_msg="HTTP ${http_code}"
    fi
    if [[ "${DETECT_DEBUG}" == "1" ]]; then
      echo "DEBUG vllm-stt bad status: ${err_msg}" >&2
      sed -n '1,80p' "${log_file}" >&2 || true
    fi
    rm -f "${wav_file}" "${json_file}" "${log_file}" "${tmp_base}"
    return 1
  fi

  python3 - "${json_file}" <<'PY'
import json
import sys

path = sys.argv[1]
text = ""
try:
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    if isinstance(payload, dict):
        value = payload.get("text", "")
        if isinstance(value, str):
            text = value.strip()
except Exception:
    text = ""
print(text)
PY
  rc=$?
  rm -f "${wav_file}" "${json_file}" "${log_file}" "${tmp_base}"
  return ${rc}
}

verify_vllm_server() {
  local url="${VLLM_BASE_URL%/}/v1/models"
  local rc=0
  curl -sS --max-time 3 "${url}" >/dev/null 2>&1 || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo "vLLM server unreachable: ${url} (profile='${VLLM_STT_PROFILE}' model='${VLLM_STT_MODEL}')" >&2
    echo "Start server first, e.g.: vllm-mlx serve <model> --port 8000" >&2
    return 1
  fi
  return 0
}

if [[ "${STT_BACKEND}" == "vllm" ]]; then
  verify_vllm_server || exit 1
fi

run_stt_once() {
  case "${STT_BACKEND}" in
    shortcuts)
      run_stt_shortcuts
      ;;
    vllm)
      run_stt_vllm
      ;;
    *)
      return 2
      ;;
  esac
}

verify_call_accepted_after_click() {
  local timeout="${ACCEPT_VERIFY_TIMEOUT_SECONDS}"
  local clear_need="${ACCEPT_VERIFY_CLEAR_COUNT}"
  local clear_streak=0
  local start_ts now_ts
  local line=""

  start_ts="$(date +%s)"
  while true; do
    now_ts="$(date +%s)"
    if [[ $((now_ts - start_ts)) -ge "${timeout}" ]]; then
      return 1
    fi

    set +e
    line="$("${BIN}" --detect 2>/dev/null)"
    set -e

    if [[ "${line}" == RINGING$'\t'* ]]; then
      clear_streak=0
      if [[ "${DETECT_DEBUG}" == "1" ]]; then
        echo "DEBUG verify-accept: still ringing"
      fi
    else
      clear_streak=$((clear_streak + 1))
      if [[ "${DETECT_DEBUG}" == "1" ]]; then
        echo "DEBUG verify-accept: clear ${clear_streak}/${clear_need}"
      fi
      if [[ ${clear_streak} -ge ${clear_need} ]]; then
        return 0
      fi
    fi

    sleep "${ACCEPT_VERIFY_POLL_SECONDS}"
  done
}

tts_pid=""

is_tts_running() {
  [[ -n "${tts_pid}" ]] && kill -0 "${tts_pid}" >/dev/null 2>&1
}

stop_tts() {
  if is_tts_running; then
    kill "${tts_pid}" >/dev/null 2>&1 || true
    wait "${tts_pid}" 2>/dev/null || true
  fi
  tts_pid=""
}

start_tts() {
  local text="$1"
  if [[ "${ENABLE_TTS}" != "1" ]]; then
    return
  fi
  if [[ "${TTS_ASYNC}" == "1" ]]; then
    stop_tts
    say "${text}" >/dev/null 2>&1 &
    tts_pid="$!"
  else
    say "${text}" || true
  fi
}

is_probable_tts_echo() {
  local transcript="$1"
  local announce_text="$2"
  local transcript_norm announce_norm

  if [[ "${SUPPRESS_ANNOUNCE_ECHO}" != "1" ]]; then
    return 1
  fi

  transcript_norm="$(normalize_text "${transcript}")"
  announce_norm="$(normalize_text "${announce_text}")"
  if [[ -z "${transcript_norm}" || -z "${announce_norm}" ]]; then
    return 1
  fi

  # Common phrase fragments from announcement TTS likely to leak back into STT.
  if [[ "${transcript_norm}" == *"영상통화가왔습니다"* || "${transcript_norm}" == *"받으시려면"* || "${transcript_norm}" == *"말씀해주세요"* ]]; then
    return 0
  fi

  # Suppress when transcript is mostly a subset/superset of current announcement text.
  if [[ ${#transcript_norm} -ge 4 ]]; then
    if [[ "${announce_norm}" == *"${transcript_norm}"* || "${transcript_norm}" == *"${announce_norm}"* ]]; then
      return 0
    fi
  fi
  return 1
}

cleanup() {
  stop_tts
}

trap cleanup EXIT INT TERM

ring_latched=0
ring_session_key=""
handled_in_session=0
idle_streak=0
next_attempt_at=0
post_accept_holdoff_until=0
session_click_x=""
session_click_y=""
session_announce_text=""
keyword_norm="$(normalize_text "${KEYWORD}")"

echo "FaceTime guard started."
echo "Keyword='${KEYWORD}' Poll=${POLL_SECONDS}s STT backend='${STT_BACKEND}'"
if [[ "${STT_BACKEND}" == "shortcuts" ]]; then
  echo "Shortcuts name='${SHORTCUT_NAME}'"
else
  echo "vLLM STT profile='${VLLM_STT_PROFILE}' model='${VLLM_STT_MODEL}' base_url='${VLLM_BASE_URL}' device='${VLLM_AUDIO_DEVICE}' capture=${VLLM_CAPTURE_SECONDS}s"
fi
echo "Press Ctrl-C to stop."

while true; do
  now_ts="$(date +%s)"
  if [[ ${now_ts} -lt ${post_accept_holdoff_until} ]]; then
    if [[ "${DETECT_DEBUG}" == "1" ]]; then
      echo "DEBUG holdoff active: $((post_accept_holdoff_until - now_ts))s remaining"
    fi
    sleep "${POLL_SECONDS}"
    continue
  fi

  set +e
  if [[ "${DETECT_DEBUG}" == "1" ]]; then
    line="$("${BIN}" --debug-detect 2>&1)"
  else
    line="$("${BIN}" --detect 2>/dev/null)"
  fi
  rc=$?
  set -e

  if [[ "${DETECT_DEBUG}" == "1" ]]; then
    while IFS= read -r dbgline; do
      [[ -z "${dbgline}" ]] && continue
      if [[ "${dbgline}" == DEBUG* ]]; then
        echo "${dbgline}"
      fi
    done <<< "${line}"
  fi

  detect_line="$(printf '%s\n' "${line}" | awk -F'\n' '/^RINGING\t/ {print; exit}')"
  if [[ -z "${detect_line}" ]]; then
    idle_streak=$((idle_streak + 1))
    if [[ ${ring_latched} -eq 1 && ${idle_streak} -ge ${RING_CLEAR_IDLE_COUNT} ]]; then
      echo "Ring session cleared (idle streak=${idle_streak})."
      ring_latched=0
      ring_session_key=""
      handled_in_session=0
      next_attempt_at=0
      session_click_x=""
      session_click_y=""
      session_announce_text=""
      stop_tts
    fi
    sleep "${POLL_SECONDS}"
    continue
  fi

  if [[ "${detect_line}" == RINGING$'\t'* ]]; then
    idle_streak=0
    IFS=$'\t' read -r state wid owner click_x click_y green_count red_count hint source caller_raw <<< "${detect_line}"
    if [[ -z "${source}" ]]; then
      source="UNKNOWN"
    fi
    caller="$(clean_caller "${caller_raw:-}")"

    event_key="${source}:${owner}:${wid}"
    if [[ "${ring_latched}" -eq 0 || "${event_key}" != "${ring_session_key}" ]]; then
      ring_latched=1
      ring_session_key="${event_key}"
      handled_in_session=0
      next_attempt_at=0
      session_click_x="${click_x}"
      session_click_y="${click_y}"
      session_announce_text="$(build_announce_text "${caller}")"
      echo "Incoming detected: wid=${wid} owner=${owner} source=${source} green=${green_count} red=${red_count} hint=${hint} caller='${caller:-unknown}' locked_click=(${session_click_x},${session_click_y})"

      start_tts "${session_announce_text}"
    fi

    # Keep click target stable within one ring session to avoid centroid jitter.
    if [[ -z "${session_click_x}" || -z "${session_click_y}" ]]; then
      session_click_x="${click_x}"
      session_click_y="${click_y}"
    fi

    if [[ ${handled_in_session} -eq 1 ]]; then
      sleep "${POLL_SECONDS}"
      continue
    fi

    if [[ ${now_ts} -lt ${next_attempt_at} ]]; then
      sleep "${POLL_SECONDS}"
      continue
    fi

    set +e
    transcript="$(run_stt_once)"
    s_rc=$?
    set -e
    if [[ ${s_rc} -ne 0 ]]; then
      if [[ "${STT_BACKEND}" == "shortcuts" ]]; then
        echo "STT failed: shortcuts '${SHORTCUT_NAME}'"
      else
        echo "STT failed: vllm model='${VLLM_STT_MODEL}'"
      fi
      next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_SECONDS))
    else
      echo "Transcript: ${transcript}"
      transcript_norm="$(normalize_text "${transcript}")"
      if contains_keyword "${transcript_norm}" "${keyword_norm}"; then
        stop_tts
        echo "Clicking locked point: (${session_click_x},${session_click_y})"
        if "${BIN}" --click "${session_click_x}" "${session_click_y}" >/dev/null 2>&1; then
          if verify_call_accepted_after_click; then
            echo "Accepted call by voice keyword (verified)."
            handled_in_session=1
            now_ts="$(date +%s)"
            next_attempt_at=$((now_ts + COOLDOWN_SECONDS))
            post_accept_holdoff_until=$((now_ts + POST_ACCEPT_HOLDOFF_SECONDS))
          else
            echo "Click sent but acceptance not verified (still ringing)."
            now_ts="$(date +%s)"
            next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_SECONDS))
          fi
        else
          echo "Detected keyword but click failed."
          next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_SECONDS))
        fi
      elif [[ -z "${transcript_norm}" ]]; then
        echo "Transcript empty."
        next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_EMPTY_SECONDS))
      elif is_probable_tts_echo "${transcript}" "${session_announce_text}"; then
        if [[ "${DETECT_DEBUG}" == "1" ]]; then
          echo "DEBUG suppressing probable TTS echo transcript."
        else
          echo "Ignored probable TTS echo."
        fi
        next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_DURING_TTS_SECONDS))
      elif is_tts_running; then
        echo "TTS active, retrying STT quickly."
        next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_DURING_TTS_SECONDS))
      else
        echo "Keyword not matched."
        next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_SECONDS))
      fi
    fi
  fi

  sleep "${POLL_SECONDS}"
done
