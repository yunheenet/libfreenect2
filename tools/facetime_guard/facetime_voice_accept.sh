#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="${ROOT_DIR}/tools/facetime_guard/build_facetime_guard.sh"
BIN="${ROOT_DIR}/build/bin/facetime_guard"

KEYWORD="${KEYWORD:-전화받아}"
SHORTCUT_NAME="${SHORTCUT_NAME:-GamjaListenKeyword}"
POLL_SECONDS="${POLL_SECONDS:-0.7}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-8}"
ENABLE_TTS="${ENABLE_TTS:-1}"
ANNOUNCE_TEXT="${ANNOUNCE_TEXT:-영상통화가 왔습니다. 받으시려면 '전화받아'를 말씀해주세요.}"
DETECT_DEBUG="${DETECT_DEBUG:-0}"
RING_CLEAR_IDLE_COUNT="${RING_CLEAR_IDLE_COUNT:-4}"
ATTEMPT_COOLDOWN_SECONDS="${ATTEMPT_COOLDOWN_SECONDS:-4}"
POST_ACCEPT_HOLDOFF_SECONDS="${POST_ACCEPT_HOLDOFF_SECONDS:-20}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --keyword TEXT       Keyword to detect (default: ${KEYWORD})
  --shortcut NAME      Shortcuts name for dictation (default: ${SHORTCUT_NAME})
  --poll SEC           Poll interval in seconds (default: ${POLL_SECONDS})
  --cooldown SEC       Cooldown after one handled event (default: ${COOLDOWN_SECONDS})
  --no-tts             Disable TTS
  -h, --help           Show help

Environment overrides:
  KEYWORD, SHORTCUT_NAME, POLL_SECONDS, COOLDOWN_SECONDS, ENABLE_TTS, ANNOUNCE_TEXT, DETECT_DEBUG,
  RING_CLEAR_IDLE_COUNT, ATTEMPT_COOLDOWN_SECONDS, POST_ACCEPT_HOLDOFF_SECONDS
USAGE
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

if ! command -v shortcuts >/dev/null 2>&1; then
  echo "shortcuts command not found."
  exit 1
fi

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

ring_latched=0
ring_session_key=""
handled_in_session=0
idle_streak=0
next_attempt_at=0
post_accept_holdoff_until=0

echo "FaceTime guard started."
echo "Keyword='${KEYWORD}' Shortcut='${SHORTCUT_NAME}' Poll=${POLL_SECONDS}s"
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
    fi
    sleep "${POLL_SECONDS}"
    continue
  fi

  if [[ "${detect_line}" == RINGING$'\t'* ]]; then
    idle_streak=0
    IFS=$'\t' read -r state wid owner click_x click_y green_count red_count hint source <<< "${detect_line}"
    if [[ -z "${source}" ]]; then
      source="UNKNOWN"
    fi

    event_key="${source}:${owner}:${wid}"
    if [[ "${ring_latched}" -eq 0 || "${event_key}" != "${ring_session_key}" ]]; then
      ring_latched=1
      ring_session_key="${event_key}"
      handled_in_session=0
      next_attempt_at=0
      echo "Incoming detected: wid=${wid} owner=${owner} source=${source} green=${green_count} red=${red_count} hint=${hint}"

      if [[ "${ENABLE_TTS}" == "1" ]]; then
        say "${ANNOUNCE_TEXT}" || true
      fi
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
    transcript="$(shortcuts run "${SHORTCUT_NAME}" 2>/dev/null)"
    s_rc=$?
    set -e
    if [[ ${s_rc} -ne 0 ]]; then
      echo "Shortcut failed: ${SHORTCUT_NAME}"
      next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_SECONDS))
    else
      echo "Transcript: ${transcript}"
      if [[ "$(normalize_text "${transcript}")" == *"$(normalize_text "${KEYWORD}")"* ]]; then
        if "${BIN}" --click "${click_x}" "${click_y}" >/dev/null 2>&1; then
          echo "Accepted call by voice keyword."
          handled_in_session=1
          next_attempt_at=$((now_ts + COOLDOWN_SECONDS))
          post_accept_holdoff_until=$((now_ts + POST_ACCEPT_HOLDOFF_SECONDS))
        else
          echo "Detected keyword but click failed."
          next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_SECONDS))
        fi
      else
        echo "Keyword not matched."
        next_attempt_at=$((now_ts + ATTEMPT_COOLDOWN_SECONDS))
      fi
    fi
  fi

  sleep "${POLL_SECONDS}"
done
