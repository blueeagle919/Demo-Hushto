# Hushto — iOS 스캔 카메라

Figma의 `04 Prototype` 화면을 SwiftUI로 옮긴 Xcode 프로젝트입니다. 외부 패키지, 계정, API 키 없이 실행합니다. iOS 17 이상을 대상으로 합니다.

## Xcode에서 실행

1. `Hushto.xcodeproj`를 엽니다.
2. 상단 Scheme에서 `Hushto`와 iPhone 시뮬레이터를 선택합니다.
3. ⌘R로 실행합니다. 시뮬레이터에서는 자체 제작한 학습 노트 샘플로 촬영을 체험할 수 있습니다.
4. 실제 iPhone에서는 Target → Signing & Capabilities → Team에 본인의 Apple 개발 계정을 선택합니다. 필요하면 Bundle Identifier를 고유한 값으로 변경합니다.
5. iPhone을 연결하고 실행한 뒤 카메라 권한을 허용합니다.

## 구현한 흐름

- 카메라: 사진·문서·칠판·스크린·동영상 모드, 전후면 전환, 토치, 사진 가져오기
- 무음 촬영: iOS 18 이상에서 공식 셔터음 억제 지원 시 최대 사진 해상도, 미지원 시 최대 네이티브 영상 프레임 저장
- 자동 촬영: 문서·칠판·스크린에서 사각형의 위치가 안정되면 촬영
- 문서·칠판·스크린: 촬영 확인 → 추가 촬영 / 사진 보정 / 페이지 관리
- 보정: 원본·자동·선명·흑백, 밝기·대비, 네 모서리 개별 자르기·원근 보정, 좌우 90° 회전·재설정
- 페이지: 앱 재실행 후 복원, 이름 변경, 순서 변경, 다중 선택·삭제
- 중복 경고: 32×32 공간 밝기 지문 비교 후 추가 여부 선택
- PDF: 파일명 검증, 원본·A4·레터, 화질 선택, 페이지 수 검증, 앱 문서 폴더에 저장, 열기·시스템 공유·파일 앱으로 내보내기
- 설정: 기본 모드·보정·플래시, 무음·촬영 피드백, 저장 공간 표시, 저장한 PDF 목록
- 사진·동영상: 사진 앱에 바로 자동 저장 (완료 팝업 없음) (PDF 세션에 추가하지 않음)
- 권한 거절, 카메라 중단, 처리·저장 실패 시 안내

## 구현 방식과 범위

카메라는 AVFoundation, 문서 검출은 Core Image의 `CIDetectorTypeRectangle`, 원근 보정은 `CIPerspectiveCorrection`, PDF는 `UIGraphicsPDFRenderer`를 사용합니다. OpenCV의 Canny/Contour를 직접 포팅한 구현은 아닙니다. Core Image의 전통적 사각형 검출을 사용하며 AI 모델과 서버 통신은 없습니다.

촬영본과 `session.json`은 앱의 `Documents/Hushto` 폴더에 저장합니다. PDF도 같은 폴더에 저장하며, 시스템 공유에서 ‘파일에 저장’을 선택할 수 있습니다. 같은 이름의 PDF는 덮어쓰지 않습니다. 현재 스캔 세션 하나를 유지하고, 생성한 PDF는 별도 파일로 보관합니다.

720p 고정을 제거했습니다. 영상 프레임은 기기가 제공하는 최대 네이티브 크기(최대 변 4096 이내, 15~30fps 지원 형식)를 선택하고 미리보기 크기 축소를 끕니다. iOS 18 이상에서 `isShutterSoundSuppressionSupported`가 참이면 공식 무음 사진 촬영으로 전환하고 `maxPhotoDimensions`를 최대 지원 크기로 지정합니다. 미지원 시 영상 프레임만 사용하며 일반 유음 촬영으로 자동 전환하지 않습니다. 모든 iPhone에서 4032px 이상을 보장하지는 않으며 실제 해상도는 설정 → 촬영 방식 확인에서 확인합니다. 원본·보정 저장의 2400px 강제 축소를 제거했고, 검출 640px·편집 미리보기 900px·썸네일 360px은 유지합니다. PDF 고화질은 최대 변 4032px입니다. 실제 iPhone 센서 해상도·촬영음·발열은 실기기 검증이 필요합니다.

Figma의 고정 상태바와 홈 인디케이터는 iOS 시스템 영역으로 처리했습니다. 정적 데모 사진 대신 사용자가 촬영한 이미지와 실제 페이지 수·파일 크기를 표시합니다. 설정·내비게이션·공유는 iOS 기본 컨트롤을 사용합니다. 원본 디자인 이미지 및 SVG는 `DesignReferences`에 보관하며 앱에는 복사하지 않습니다. `DemoPage*` 이미지는 앱 에셋에서 제거했습니다. 시뮬레이터용 `CameraSample`과 모서리 에셋은 `SimulatorAssets.xcassets`로 분리하고 iPhoneOS 빌드에서 제외했습니다.

## 검증과 배포 준비

최신 실행 결과와 남은 제출 요건은 [Release/RELEASE_READINESS.md](Release/RELEASE_READINESS.md)에 기록합니다. XCTest는 Xcode에서 ⌘U로 실행합니다. 앱 안 설정 → 촬영 방식 확인에서 무음 프레임과 시스템 사진 요청 횟수를 확인할 수 있습니다. 이 값은 실제 촬영음 측정 결과가 아닙니다.

## 핵심 규칙 테스트 재실행

프로젝트 폴더에서 실행합니다.

```sh
xcrun swiftc Hushto/CoreRules.swift Tests/CoreRulesChecks.swift -o /tmp/HushtoCoreRulesChecks
/tmp/HushtoCoreRulesChecks
```

## 참고

- [Figma High Fidelity](https://www.figma.com/design/FmY8xpKiZZ7XMtyNvenOn3/App-Design?node-id=10-5)
- [Apple: AVCaptureVideoDataOutput](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput)
- [Apple: Rectangle detector](https://developer.apple.com/documentation/coreimage/cidetectortyperectangle)
- [Apple: Perspective correction](https://developer.apple.com/documentation/coreimage/cifilter/3228380-perspectivecorrection)

## 화면 크기 대응 업데이트

카메라 미리보기의 너비를 안전 영역 내부 너비에 고정하고 높이는 가용 화면 높이와 비율에 맞춥니다. 작은 화면에서는 여백을 줄이고, 촬영 확인·보정·PDF 화면은 세로 스크롤을 지원합니다. PDF 파일명 입력 시 키보드가 표시되어도 저장 버튼까지 스크롤할 수 있습니다.

문서 폴더에 복사한 프로젝트는 `~/Documents/Hushto/Hushto.xcodeproj`에서 열 수 있습니다. 이전에 열었던 프로젝트 대신 이 파일을 연 뒤 ⇧⌘K, ⌘R로 실행하세요.

## 저장·공유 흐름 업데이트

사진·동영상 모드에서 새로 촬영한 미디어는 사진 추가 권한을 받아 갤러리에 즉시 저장합니다. 저장 실패 시 완료로 표시하지 않으며, 촬영본을 유지한 채 재시도·설정 열기·명시적 폐기를 제공합니다. 성공 시 결과창이나 확인창 없이 촬영 화면을 유지하고, 동영상 임시 파일은 갤러리 저장 성공 후 제거합니다. 기존에 저장한 파일은 자동 삭제하거나 이동하지 않습니다.

문서·칠판·스크린 촬영은 PDF 임시 저장소인 촬영 확인 화면으로 이동합니다. 이 화면에서 보정하거나 다음 촬영을 이어가고, 페이지 관리에서 PDF로 통합합니다. 스캔 문서 목록에서 페이지를 길게 눌러 끌어 옮기며, VoiceOver에는 앞으로/뒤로 이동 동작을 제공합니다. 사진 보정과 다음 촬영 버튼은 iOS 기본 버튼 스타일을 사용합니다. PDF 저장 완료·공유 화면의 완료 버튼은 촬영 화면으로 돌아갑니다. 사진 가져오기는 PDF 스캔에 추가하는 기존 동작을 유지합니다.

## 새 스캔과 화면 모드

PDF 저장 성공 시 현재 촬영 세션을 비우고 새 문서로 시작합니다. 홈의 페이지 관리 표시도 사라집니다. 저장한 PDF는 유지되며, 완료 화면에서 원래 페이지 수로 열기·공유할 수 있습니다. PDF 저장 실패 시 촬영본은 유지됩니다.

설정 → 화면 → 화면 모드에서 시스템 설정·라이트 모드·다크 모드를 선택합니다. 기본값은 시스템 설정입니다. 촬영 모드, 사진 보정, PDF Export는 시스템 segmented Picker를 사용하고, iOS 26 이상에서 Liquid Glass를 적용합니다. 이전 iOS에서는 머티리얼 배경을 사용합니다.


## 2026-10-10 · 최신 04 Prototype 보정

모드·저장·녹화·자동 인식·권한 상태에 따라 Camera/Status를 표시합니다. 편집 도구 모음은 iOS 26 이상에서 실제 Liquid Glass, 이전 iOS에서는 Material을 사용합니다. 자르기는 네 모서리 위치를 독립적으로 저장하고 교차·퇴화 사각형을 막으며, 상단 체크로 적용합니다. 회전을 선택하면 왼쪽 90°·오른쪽 90°·재설정 패널이 나타납니다. 보정은 원본에서 다시 렌더링하여 반복 편집 시 원본을 덮어쓰지 않습니다.

참고: [Apple 공식 무음 촬영 지원](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isshuttersoundsuppressionsupported), [최대 사진 크기](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/maxphotodimensions). [Screet App Store 설명](https://apps.apple.com/us/app/screet-black-screen-camera/id6758235938)의 영상 프레임 기반 무음 저장 방식도 참고했습니다. 타사 사진의 실제 4032px 촬영 여부를 직접 검사한 것은 아닙니다.

## 고해상도 촬영 선명도 개선

네이티브 프레임의 실제 픽셀 수를 우선하고, 같은 크기에서는 비닝 없는 포맷과 큰 사진 해상도를 우선합니다. 4032×3024를 제공하는 기기는 3840×2160보다 해당 전체 센서 프레임을 우선합니다. 연속 자동초점·자동노출·자동 화이트밸런스를 설정하며, 무음 프레임 촬영 시 초점/노출 조정 중이면 최대 0.8초 기다립니다. 포맷 변경 직후 들어오는 작은 이전 프레임은 저장하지 않습니다. 영상 프레임의 전자식 흔들림 보정을 끄고 원본 크기를 유지합니다. 지원되는 경우 네이티브 YUV 버퍼를 사용하여 매 프레임 BGRA 변환을 피합니다. 스캔 원본 JPEG 품질은 0.98, 보정본은 0.96으로 올렸습니다. PDF 화질 선택은 별도로 유지됩니다.

이 설정은 출력 크기를 인위적으로 확대하지 않습니다. 실기기의 지원 포맷과 실제 촬영본 해상도·초점·촬영음을 함께 확인해야 4K/12MP 지원을 확정할 수 있습니다.

## 2026-10-11 · 자동 스캔 / 촬영 모드 Glass

문서·칠판·스크린에서 오른쪽 위 자동 촬영을 켜면 검출된 네 모서리가 약 1초 동안 안정될 때 무음 촬영하고 촬영 확인으로 이동합니다. 검출 후보를 최대 8개 조사해 큰 문서를 선택하고, 실제 검출 이미지의 가로·세로에 맞춰 좌표를 정규화합니다. 작은 손떨림과 짧은 인식 끊김을 허용하며, 움직임·문서 이탈·촬영 중에는 추가 촬영을 막습니다. 스캔 모드 간 이동에서는 자동 촬영을 유지하며 사진·동영상으로 이동하면 끕니다.

시뮬레이터/Canvas에도 문서 검출과 같은 안정화 판정을 사용하는 샘플 자동 촬영 경로를 추가했습니다. 카메라 없는 미리보기에서만 샘플을 사용합니다. 촬영 모드 선택기는 기본 segmented 회색 배경을 제거하고 보정 도구 모음과 같은 Glass 캡슐 및 label/onAccent 선택 색상으로 통일했습니다.
