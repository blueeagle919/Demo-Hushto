# Demo-Hushto

오프라인 사진·동영상 촬영 및 문서 스캔 iPhone/iPad 앱입니다. SwiftUI, AVFoundation, Vision, Core Image, PDFKit을 사용하며 외부 패키지나 서버 없이 동작합니다.

## 실행

1. `Demo-Hushto.xcodeproj`를 엽니다.
2. `Demo-Hushto` 스킴과 실행할 iPhone/iPad를 선택합니다.
3. 실제 기기는 Signing & Capabilities에서 본인의 개발팀을 확인하고 Run(⌘R)으로 실행합니다.

- 앱 이름: **Demo-Hushto**
- Swift 모듈: `Demo_Hushto` (Swift 모듈은 하이픈을 지원하지 않습니다.)
- 최소 지원: iOS/iPadOS 17
- 기존 설치·저장 데이터 호환을 위해 Bundle ID `app.hushto`, 저장 폴더 및 설정 키를 유지합니다.
- iOS/iPadOS 26 이상은 네이티브 Liquid Glass, 이전 버전은 시스템 Material을 사용합니다.

## 기능

- 사진·동영상은 사진 앱에 저장하며 영상에는 마이크 입력을 사용하지 않습니다.
- 스캔 촬영은 촬영 확인, 필터·밝기·대비·모서리 자르기·회전·3D 기울기 보정을 거쳐 여러 페이지 PDF로 내보냅니다.
- 자동 문서 감지·원근 보정·중복 확인·페이지 관리·공유·저장 실패 복구를 지원합니다.
- iPhone과 iPad의 촬영·저장 흐름을 공유하고 화면 크기에 맞춰 레이아웃을 조정합니다.
- 무음 촬영 가능 방식과 해상도는 기기 지원 능력에 따라 결정합니다.

## 구조

`Demo-Hushto/`에는 App, Core, DesignSystem, Camera, Imaging, Editor, Pages, Export, Storage, Settings 폴더가 있습니다. 단위 테스트는 `Demo-HushtoTests`, UI 테스트는 `Demo-HushtoUITests`에 있습니다.

## 검증

```sh
xcrun swiftc Demo-Hushto/Core/CoreRules.swift Demo-Hushto/Core/CaptureMode.swift Tests/CoreRulesChecks.swift -o /tmp/Demo-HushtoCoreChecks
/tmp/Demo-HushtoCoreChecks
```

앱 빌드 예시(서명 제외):

```sh
xcodebuild -project Demo-Hushto.xcodeproj -scheme Demo-Hushto -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

실제 기기의 카메라·권한·소리·저장·장시간 발열·최대 메모리는 별도 검증이 필요합니다. 과거 검증 기록은 당시 버전 기준이며 현재 변경의 검증을 대신하지 않습니다.

## 디자인 출처

[Figma · Husto Advanced App Design](https://www.figma.com/design/ZBmZpAWeSj49Lr7wmFimII/Husto-Advanced-App-Design?node-id=1-8)

## 이름 변경 · 2026-10-31

프로젝트·스킴·제품·앱 표시 이름·테스트 타깃·관련 파일/폴더를 Demo-Hushto로 변경했습니다. 사용자 데이터 호환을 위한 내부 식별자와 공개 문서 URL은 유지합니다. 앱 동작과 화면 배치를 변경하는 작업은 포함하지 않습니다.
