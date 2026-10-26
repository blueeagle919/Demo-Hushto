# iPad 레이아웃 구현 — 2026-10-19

## 기준

Figma `FmY8xpKiZZ7XMtyNvenOn3`의 04 Prototype (`10:6`)에 있는 iPad Landscape 1194×834 / Portrait 834×1194 프레임을 직접 조회했습니다. 사용자가 처음 언급한 Notion은 Figma를 뜻하는 것으로 정정했습니다.

- 카메라: `359:1024`, `359:10981`
- 촬영 확인: `359:1797`, `359:11359`
- 보정: `359:1821`, `359:11383`
- 페이지 관리: `359:2301`, `359:11462`
- PDF 내보내기: `359:2602`, `359:11510`
- PDF 완료: `359:2656`
- 설정: `359:3232`

## 구현

- iPad에서만 별도 화면을 선택하는 `HushtoRootScreen`을 추가했습니다. iPhone에서는 기존 `CameraScreen`을 그대로 반환합니다.
- iPad 카메라: 가로에서는 왼쪽 뷰파인더와 오른쪽 세로 모드 선택기·촬영 버튼, 세로에서는 뷰파인더 아래 가로 선택기·촬영 버튼을 표시합니다.
- 촬영 확인: 가로 미리보기/동작 패널, 세로 미리보기/가로 버튼 행.
- 사진 보정·모서리 자르기: 가로 미리보기/오른쪽 도구·설정, 세로 미리보기/하단 도구·설정. 기존 필터·조절·회전·네 모서리 드래그 동작을 연결했습니다.
- 페이지 관리: 두 열의 페이지 카드와 드래그 순서 변경, 가로 오른쪽 PDF 작업 / 세로 하단 PDF 작업.
- PDF: 가로 왼쪽 문서 미리보기/오른쪽 옵션, 세로 옵션 아래 문서 미리보기. 저장 완료의 열기·공유 버튼도 기존 glass 스타일을 사용합니다.
- 설정: 시스템 NavigationSplitView 사이드바와 기존 설정 항목. 사이드바에서 해당 설정 섹션으로 이동합니다.
- 다크모드 토큰, Liquid Glass, 기존 이미지·아이콘 자산과 촬영/저장 모델을 재사용했습니다. 새 네트워크 기능은 없습니다.
- 좁은 창에서는 세로 구성을 사용하고 카메라는 스크롤로 컨트롤에 접근할 수 있습니다.
- 앱의 iPad 기기 지원과 iPad 전용 네 방향 회전 선언을 추가했습니다. iPhone 회전 선언은 그대로입니다.
- 기존 아이콘 원본에서 iPad 필수 크기를 생성했습니다. 기존 iPhone 아이콘 이미지는 변경하지 않았습니다.

## 아이폰 보존

작업 전 파일과 SHA-256/바이트 비교로 아래 파일이 그대로임을 확인했습니다.

`CameraScreen.swift`, `ScanScreens.swift`, `SettingsScreen.swift`, `CameraScreenPreview.swift`, `Camera.swift`, `CoreRules.swift`, `Imaging.swift`, `ScanStore.swift`, `Models.swift`, `ReleaseInfo.swift`.

`HushtoApp.swift`는 앱 진입점의 `CameraScreen()`을 기기 분기용 `HushtoRootScreen()`으로 바꾼 부분 외에는 동일합니다. 공유 컨트롤 구현과 앱 테마도 변경하지 않았습니다. Info.plist는 iPad 방향 키를 제거해 비교했을 때 원본과 동일합니다.

## 검증

- arm64 iOS Simulator Debug 빌드 통과 (`work/ipad-verified-build.log`).
- iPad Pro/Mini 가로·세로, 좁은 창의 뷰파인더 양수 크기·가용 폭 검사 통과 (`work/IPadLayoutChecks.swift`).
- 기존 줌·자동 촬영·프레임 시간·고해상도 선택·파일명·중복·무음 경로 규칙 회귀 검사 통과.
- iPhone 원본 소스와 방향 설정 보존 검사 통과.
- iPad 필수 아이콘 누락 경고를 해소했습니다.

## 화면 실행 검수 제한

Device Hub에서 iPad Pro 11-inch (M5)를 연결했으나 `Connecting display…` 이후 `Connection timed out`가 표시됐습니다. 설치·실행 요청도 CoreSimulator의 Mach -308 / 서버 종료 오류로 끝났습니다. 검수를 위해 부팅한 해당 시뮬레이터는 종료했습니다. 이 결과는 앱 실행 성공이 아닙니다.

Xcode에는 `IPadLayout.swift`의 가로·세로 PreviewProvider를 추가하고 Canvas 기기를 iPad 11-inch로 선택했습니다. Canvas도 iPad Simulator 준비 단계에 머물러, 아이패드 화면의 시각 검수와 터치·회전 검수는 아직 완료하지 못했습니다. 소스 및 빌드 검증과 실제 iPad 실행 검증을 구분합니다. 실제 iPad에는 설치하지 않았습니다.

추가 검증 기록:
- 시뮬레이터 화면 검수 실패 후 Canvas에서도 준비가 멈췄고 화면 조작 연결이 끊겼습니다. 연결을 재초기화했으나 Xcode 스크린샷을 얻지 못했습니다.
- 기기 Release 빌드는 환경 지연 중 중단했습니다 (`work/ipad-release-build.log`). Release 통과로 기록하지 않습니다.
- 최종 페이지 카드 크기와 iPad 미리보기 방향 선언을 포함한 Debug 재검사 로그는 `work/ipad-final-check.log`입니다.

최종 Debug 재검사: `BUILD SUCCEEDED` 확인. 최신 페이지 카드 크기·가로/세로 Preview 선언까지 포함한 소스입니다.
