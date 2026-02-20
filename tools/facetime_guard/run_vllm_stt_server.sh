#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_DIR="${VENV_DIR:-${ROOT_DIR}/.venv-vllm}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
LLM_MODEL="${LLM_MODEL:-mlx-community/Llama-3.2-1B-Instruct-4bit}"
STT_PROFILE="${STT_PROFILE:-ko-fast}"
STT_MODEL="${STT_MODEL:-}"
STT_LANGUAGE="${STT_LANGUAGE:-}"
PRINT_ENV_ONLY=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Start vllm-mlx server for FaceTime guard STT use.

Options:
  --profile NAME       STT profile: ko-fast|ko-accurate|ko-lite|en-fast (default: ${STT_PROFILE})
  --stt-model NAME     Explicit STT model alias/HF id (overrides --profile)
  --stt-language CODE  Explicit STT language (default: auto by profile)
  --llm-model NAME     Base model for vllm-mlx serve (default: ${LLM_MODEL})
  --host HOST          Bind host (default: ${HOST})
  --port PORT          Bind port (default: ${PORT})
  --venv PATH          Python venv path (default: ${VENV_DIR})
  --print-env          Print export commands and exit
  -h, --help           Show help
USAGE
}

resolve_stt_model_by_profile() {
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

resolve_stt_language_by_profile() {
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
    --profile)
      STT_PROFILE="$2"
      shift 2
      ;;
    --stt-model)
      STT_MODEL="$2"
      shift 2
      ;;
    --stt-language)
      STT_LANGUAGE="$2"
      shift 2
      ;;
    --llm-model)
      LLM_MODEL="$2"
      shift 2
      ;;
    --host)
      HOST="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --venv)
      VENV_DIR="$2"
      shift 2
      ;;
    --print-env)
      PRINT_ENV_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${STT_MODEL}" ]]; then
  if ! STT_MODEL="$(resolve_stt_model_by_profile "${STT_PROFILE}")"; then
    echo "Unsupported profile: ${STT_PROFILE}" >&2
    echo "Use one of: ko-fast, ko-accurate, ko-lite, en-fast" >&2
    exit 1
  fi
fi

if [[ -z "${STT_LANGUAGE}" ]]; then
  if ! STT_LANGUAGE="$(resolve_stt_language_by_profile "${STT_PROFILE}")"; then
    echo "Unsupported profile: ${STT_PROFILE}" >&2
    exit 1
  fi
fi

if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
  echo "Missing venv activate script: ${VENV_DIR}/bin/activate" >&2
  echo "Create and install first, e.g.:" >&2
  echo "  python3 -m venv ${VENV_DIR}" >&2
  echo "  source ${VENV_DIR}/bin/activate && pip install -U pip && pip install vllm-mlx mlx-audio" >&2
  exit 1
fi

source "${VENV_DIR}/bin/activate"

if ! command -v vllm-mlx >/dev/null 2>&1; then
  echo "vllm-mlx not found in ${VENV_DIR}" >&2
  exit 1
fi

if [[ "${STT_MODEL}" == whisper* ]]; then
  if ! python - <<'PY' >/dev/null 2>&1
import tiktoken
PY
  then
    echo "Missing Python module: tiktoken (required for Whisper STT)." >&2
    echo "Install in venv: pip install tiktoken" >&2
    exit 1
  fi
fi

echo "Recommended env for FaceTime guard:"
echo "  export STT_BACKEND=vllm"
echo "  export VLLM_BASE_URL=http://${HOST}:${PORT}"
echo "  export VLLM_STT_MODEL=${STT_MODEL}"
echo "  export VLLM_STT_LANGUAGE=${STT_LANGUAGE}"
echo "  export VLLM_STT_PROFILE=${STT_PROFILE}"

if [[ ${PRINT_ENV_ONLY} -eq 1 ]]; then
  exit 0
fi

echo
echo "Starting vllm-mlx server..."
echo "  host=${HOST} port=${PORT}"
echo "  llm_model=${LLM_MODEL}"
echo "  stt_profile=${STT_PROFILE} stt_model=${STT_MODEL} stt_language=${STT_LANGUAGE}"
echo
echo "Press Ctrl-C to stop."

exec vllm-mlx serve "${LLM_MODEL}" --host "${HOST}" --port "${PORT}"
