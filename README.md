# mdir-cli

참조 프로젝트 `/Users/jayusop/Develop/codex/mdir`의 방향을 반영한 macOS용 CLI `mdir` 0.2입니다.
과거 DOS 시절 `MDIR` 감성과 Shell File Manager 성격을 섞어 듀얼 패널 중심의 터미널 파일 매니저로 구성했습니다.

핵심 특징:

- TTY에서는 인터랙티브 듀얼 패널 파일 매니저로 실행
- 한 경로 입력 시 좌우 패널이 같은 시작 경로로 열림
- 두 디렉터리 입력 시 좌우 패널 시작 경로를 각각 지정
- 두 파일 입력 시 크기와 첫 차이 offset 비교
- POSIX 권한, owner, group, 수정 시각, 크기 표시
- `.app` 폴더를 애플리케이션 번들로 인식해 실행 가능
- 숨김 파일 토글과 정렬 순환을 키 입력으로 처리
- 비대화형 환경 또는 `MDIR_FORCE_BATCH=1`에서는 스냅샷 출력
- Swift Package 구조라 Xcode에서 `Package.swift`를 열어 바로 빌드 가능

## Build

```bash
swift build
./.build/debug/mdir
./scripts/smoke-test.sh
```

Xcode에서는 `Package.swift`를 열면 패키지 프로젝트로 인식됩니다. 실행 스킴에서 `mdir` 타깃을 선택해 빌드/실행하면 됩니다.

## Install

기본 설치 경로는 `~/.local/bin/mdir`입니다.

```bash
zsh scripts/install.sh
export PATH="$HOME/.local/bin:$PATH"
mdir /h
```

다른 경로에 설치하려면:

```bash
PREFIX="$HOME/tools" zsh scripts/install.sh
BINDIR="/usr/local/bin" zsh scripts/install.sh
```

릴리스 빌드 대신 이미 빌드된 바이너리를 재사용하려면:

```bash
MDIR_SKIP_BUILD=1 BUILD_CONFIG=debug zsh scripts/install.sh
```

제거:

```bash
zsh scripts/uninstall.sh
```

## Release

릴리스 아카이브 생성:

```bash
zsh scripts/package-release.sh
```

생성 결과는 `dist/mdir-macos-<arch>.tar.gz`이며, 마지막 줄에 `sha256`이 출력됩니다.

Homebrew formula 생성:

```bash
zsh scripts/generate-formula.sh 1.0.0 \
  https://example.com/mdir-macos-arm64.tar.gz \
  <sha256>
```

생성 결과는 `Formula/mdir.rb`입니다.

자세한 절차는 [docs/RELEASING.md](/Users/jayusop/Develop/codex/mdir-cli/docs/RELEASING.md), 버전별 변경 이력은 [CHANGELOG.md](/Users/jayusop/Develop/codex/mdir-cli/CHANGELOG.md)를 참고하면 됩니다.

## Usage

```bash
./.build/debug/mdir
./.build/debug/mdir /path/to/directory
./.build/debug/mdir /left/path /right/path
./.build/debug/mdir left.bin right.bin
MDIR_FORCE_BATCH=1 ./.build/debug/mdir /path/to/directory
./.build/debug/mdir /a:h
./.build/debug/mdir /o:s /left/path /right/path
./.build/debug/mdir /h
```

## Interactive Keys

- `Left`: 왼쪽 패널 활성화
- `Right`: 오른쪽 패널 활성화
- `Tab`: 활성 패널 전환
- `Up` / `Down`: 선택 이동
- `Enter`: 디렉터리 진입, `.app` 실행, 또는 현재 사용자 기준 실행 가능한 파일을 인자 입력 후 실행하고 `[Press Anykey]` 대기
- `O`: 선택한 `.app` 폴더의 내부 내용 열기
- `Backspace`: 상위 디렉터리 이동
- `E`: 선택한 파일을 `vi`로 편집
- `P`: 권한 입력 모드 시작 (`644`, `755` 등 입력 후 `Enter` 적용, `Esc` 취소)
- `H`: 숨김 파일 표시 토글
- `S`: 정렬 기준 순환
- `C`: 좌우 패널 선택 파일 비교
- `R`: 새로고침
- `Q`: 종료

## Startup Options

- `/h` 또는 `/?`: 도움말 출력
- `/a:h`: 시작 시 숨김 파일 표시
- `/o:n`: 이름 정렬로 시작
- `/o:s`: 크기 정렬로 시작
- `/o:d`: 수정 시각 정렬로 시작

## Batch Mode

- `MDIR_FORCE_BATCH=1`이면 비대화형 스냅샷 출력
- CI나 파이프 환경에서는 자동으로 배치 모드 사용

## Compare

- 디렉터리 두 개를 주면 좌우 패널 형태로 나란히 출력
- 파일 두 개를 주면 크기와 첫 차이 위치를 비교
