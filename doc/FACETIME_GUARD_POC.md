# FaceTime Guard POC (Screen + Color + Voice Keyword)

목표:
- FaceTime 수신 카드(우측 상단)를 UI 트리(AX) 의존 없이 감지
- `전화받아` 음성 키워드 인식 시 수락 버튼 좌표 클릭

핵심 방식:
1. `CGWindowList`로 상단 우측 후보 윈도우 탐색
2. 후보 윈도우 이미지에서 초록/빨강 버튼 색 픽셀 분석
3. 수신으로 판정되면 키워드 STT 실행
4. 키워드 매치 시 수락 버튼 추정 좌표 클릭

## 파일

- `/Users/yuni/Dev/libfreenect2/tools/facetime_guard/facetime_guard.m`
- `/Users/yuni/Dev/libfreenect2/tools/facetime_guard/build_facetime_guard.sh`
- `/Users/yuni/Dev/libfreenect2/tools/facetime_guard/facetime_voice_accept.sh`

## 권한

1. `Screen Recording`:
   - 실행 앱(터미널 앱)에 화면 기록 권한 필요
2. `Accessibility`:
   - 실행 앱(터미널 앱)에 제어 권한 필요 (클릭 이벤트 전송)
3. `Shortcuts`:
   - `GamjaListenKeyword` 단축어 준비 (Dictate Text -> Stop and Output)

## 빌드

```bash
cd /Users/yuni/Dev/libfreenect2
./tools/facetime_guard/build_facetime_guard.sh
```

## 단발 테스트

```bash
/Users/yuni/Dev/libfreenect2/build/bin/facetime_guard --detect
```

출력:
- `RINGING ...` : 수신 카드 감지
- `IDLE` : 미감지

`RINGING` 포맷:
- `RINGING\twid\towner\tclickX\tclickY\tgreen\tred\thint\tsource\tcaller`
- `caller`는 감지 시 추정한 발신자 이름(실패 시 `UNKNOWN`)

디버그:

```bash
/Users/yuni/Dev/libfreenect2/build/bin/facetime_guard --debug-detect
```

`source` 값:
- `WINDOW`: 윈도우 기반 감지
- `PID+GREEN`: `FaceTimeNotification*` PID + 상단 우측 초록 버튼 스캔 fallback

민감도 튜닝:

```bash
FACETIME_GUARD_GREEN_LOCAL_THRESHOLD=750 /Users/yuni/Dev/libfreenect2/build/bin/facetime_guard --debug-detect
```

기본값은 `850`이며, 수신 중 미감지면 `700~800` 범위로 낮춰 테스트.

클릭 오프셋 튜닝(`PID+GREEN` 경로):

```bash
FACETIME_GUARD_FALLBACK_OFFSET_X=20 FACETIME_GUARD_FALLBACK_OFFSET_Y=-1 /Users/yuni/Dev/libfreenect2/build/bin/facetime_guard --debug-detect
```

발신자 OCR ROI 튜닝(`PID+GREEN` 경로):

```bash
FACETIME_GUARD_CALLER_ROI_W=760 FACETIME_GUARD_CALLER_ROI_H=220 FACETIME_GUARD_CALLER_ROI_ANCHOR_X=0.72 FACETIME_GUARD_CALLER_ROI_ANCHOR_Y=0.20 /Users/yuni/Dev/libfreenect2/build/bin/facetime_guard --debug-detect
```

OCR 읽기 영역 가이드 확인:

```bash
DETECT_DEBUG=1 FACETIME_GUARD_DEBUG_ROI_DIR=/tmp/facetime_guard_roi /Users/yuni/Dev/libfreenect2/build/bin/facetime_guard --debug-detect
```

- 로그에 `GUIDE caller-name/r1/r2/r3 rect=...`가 출력됨
- `/tmp/facetime_guard_roi/caller_name.png`, `caller_r1.png` 등 실제 OCR 대상 이미지가 저장됨

발신자 이름 전용 ROI 튜닝:

```bash
FACETIME_GUARD_CALLER_NAME_W=380 FACETIME_GUARD_CALLER_NAME_H=105 FACETIME_GUARD_CALLER_NAME_OFFSET_X=330 FACETIME_GUARD_CALLER_NAME_OFFSET_Y=34 /Users/yuni/Dev/libfreenect2/build/bin/facetime_guard --debug-detect
```

## 상시 실행

```bash
cd /Users/yuni/Dev/libfreenect2
./tools/facetime_guard/facetime_voice_accept.sh --no-tts
```

디버그 실행:

```bash
cd /Users/yuni/Dev/libfreenect2
DETECT_DEBUG=1 ./tools/facetime_guard/facetime_voice_accept.sh --no-tts
```

반복 전사 방지:
- 같은 수신 세션에서 한 번 수락 성공하면 추가 STT 시도 중단
- `IDLE`이 연속으로 일정 횟수 관측되면(기본 4회) 다음 수신 세션으로 전환
- STT 실패/불일치 시 재시도 쿨다운(기본 4초)
- 수락 성공 직후 감지 재트리거 방지 holdoff(기본 20초, `POST_ACCEPT_HOLDOFF_SECONDS`)
- 발신자 이름 추정 시 TTS 기본 문구:
  - `OOO에게 영상통화가 왔습니다. 받으시려면 '전화받아'를 말씀해주세요.`
  - 템플릿 변경: `ANNOUNCE_TEXT_CALLER_TEMPLATE`
- TTS/STT 동시 처리:
  - 기본값 `TTS_ASYNC=1`로 TTS 재생 중에도 STT 전사 시도 가능
  - 필요 시 동기 모드: `TTS_ASYNC=0`

## 튜닝 포인트

- 감지 민감도:
  - `/Users/yuni/Dev/libfreenect2/tools/facetime_guard/facetime_guard.m`
  - `ringingLike` 임계치(`green/red` 픽셀 수) 조정
- 클릭 좌표:
  - `PID+GREEN` 경로는 centroid 기반 클릭
  - 필요 시 `FACETIME_GUARD_FALLBACK_OFFSET_X/Y`로 미세 보정
