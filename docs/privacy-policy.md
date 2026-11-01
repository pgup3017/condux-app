# Condux 개인정보 처리 안내 (초안)

최종 수정: 2026-10-31. 배포 전에 사용자가 읽고 고친 뒤 공개 페이지에 올립니다.

## 수집하는 정보

Condux 는 자체 서버가 없습니다. 앱이 Anthropic, OpenAI 또는 다른 누구에게도 사용자 정보를 보내지 않습니다.

- **대화 기록**은 이 Mac 의 `~/Library/Application Support/VibeStudio/conversations.json` 에만 저장됩니다.
- **설정**(실행 파일 경로, 모델 선택)은 macOS 사용자 기본값(UserDefaults)에 저장됩니다.
- **로그인 정보, 토큰, API 키는 저장하거나 읽지 않습니다.** 로그인은 사용자가 설치한 공식 Codex CLI 와 Claude Code CLI 가 각자의 절차로 관리합니다.

## 외부 서비스로 가는 데이터

사용자가 메시지를 보내면, 앱이 실행한 공식 CLI 가 그 내용을 해당 서비스(OpenAI 또는 Anthropic)에 보냅니다. 이때 적용되는 약관과 개인정보 정책은 각 서비스의 것입니다:

- OpenAI Codex: https://openai.com/policies
- Anthropic Claude Code: https://www.anthropic.com/legal/consumer-terms (구독) 및 https://www.anthropic.com/legal/privacy

## 삭제

앱을 지우고 위 폴더를 삭제하면 기록이 모두 사라집니다. 각 서비스 쪽 기록은 그 서비스 설정에서 지웁니다.

## 문의

(배포 전에 연락처를 적습니다.)
