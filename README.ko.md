# Condux

[English](README.md) · [웹사이트](https://condux.co.kr) · [사용 가이드](docs/사용-가이드.md)

**여러 AI를 한 화면에서 부리는 Mac 작업실입니다.** Claude, GPT, Codex에게 일을 맡기고, 서로 검토시키고, 결과는 내가 승인합니다. 키와 로그인은 내 Mac에 그대로 둡니다.

> **초기 단계입니다.** 한 사람이 만들고 있고 빠르게 바뀝니다. 어디까지 확인됐는지는 [영어 README의 표](README.md#what-has-been-tested)를 보세요.

## 설치

macOS 14 이상의 Apple Silicon Mac이 필요합니다.

[**최신 버전 내려받기**](https://github.com/pgup3017/condux-app/releases/latest)에서 파일을 받아 압축을 풀고, `Condux.app`을 응용 프로그램 폴더로 옮기면 됩니다. Developer ID로 서명하고 Apple 공증을 받았습니다. 아직 자동 업데이트는 없으니 새 버전은 이 페이지에서 확인하세요.

### 소스에서 빌드

Xcode가 필요합니다.

```bash
git clone https://github.com/pgup3017/condux-app.git
cd condux-app
scripts/build-local.sh
```

스크립트가 앱을 빌드하고, 이 Mac 전용으로 서명한 뒤 엽니다. Xcode가 패키지 플러그인 신뢰를 물으면 `Condux.xcodeproj`를 한 번 열어 **Trust & Enable**을 누르고 다시 실행하세요.

## 연결

왼쪽 아래 연결 상태를 눌러 **연결 관리**를 엽니다.

| 연결 | 방법 |
| --- | --- |
| Claude API, OpenAI API | API 키를 넣습니다. 각 사이트에서 사용 한도를 정해 두세요. |
| Claude 구독 | Claude Code를 설치하고 **로그인 명령 복사**를 눌러 터미널에서 실행합니다. |
| Codex | Codex를 설치하고 **브라우저로 로그인**을 누릅니다. |
| GitHub | GitHub CLI를 설치하고 **로그인 명령 복사**를 눌러 터미널에서 실행합니다. |

## Chrome과 다른 프로그램

- **다른 프로그램:** **연결 관리 ▸ 다른 프로그램 제어 ▸ 제어 대화 시작**을 누르고 "Safari로 example.com을 열어 줘"처럼 시킵니다. Claude 구독 로그인이 필요하고, 처음에 macOS가 권한을 묻습니다.
- **Chrome:** **연결 관리 ▸ 도구 (MCP) ▸ 추가**에서 **chrome**을 고릅니다. Node가 필요하고, 평소 프로필과 분리된 Chrome 창에서 돌아갑니다.

## 주의

명령은 자동으로 허용되지 않습니다. 웹 페이지나 파일에 AI를 속이는 지시가 들어 있을 수 있으니, 승인하기 전에 명령을 읽어 보세요. 자세한 내용은 [SECURITY.md](SECURITY.md)를 보세요.

연결하는 각 서비스의 약관은 직접 지켜야 합니다. Condux는 독립 프로젝트이며 Anthropic, OpenAI, GitHub와 제휴 관계가 없습니다.

## 라이선스

코드는 [Apache-2.0](LICENSE)입니다. Condux 이름과 앱 아이콘은 라이선스에 포함되지 않습니다. 포크할 때는 자신의 이름과 아이콘을 써 주세요.
