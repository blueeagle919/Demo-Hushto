# App Store 제출 문안 초안

앱 이름: Hushto
부제: 오프라인 문서 스캔과 PDF
분류 제안: 생산성 (보조: 교육)
키워드: 문서,스캔,PDF,노트,필기,강의,책,오프라인,칠판,카메라

## 설명

조용한 학습 공간에서 책, 노트와 칠판을 빠르게 기록하세요.
Hushto는 서버 연결 없이 기기 안에서 문서를 보정하고 PDF로 정리합니다.

• 영상 프레임을 저장하는 무음 모드와 시각적 촬영 피드백
• 문서 사각형 자동 검출 및 원근 보정
• 원본·자동·선명·흑백 보정과 밝기·대비 조절
• 페이지 순서 변경, 중복 페이지 경고, PDF 저장 및 공유
• 계정, 광고, 분석 SDK 없이 오프라인 사용

무음 모드는 720p 영상 프레임을 사용하므로 일반 사진보다 해상도가 낮습니다. 일반 사진 모드에서는 기기 설정에 따라 촬영음이 날 수 있습니다. 실제 동작은 기기와 iOS 환경에 따라 확인이 필요합니다. 동영상은 오디오 없이 저장합니다.

## 심사 메모 (English)

No account or backend is required. Allow Camera permission on a physical iPhone. Silent mode saves a frame delivered by the public AVCaptureVideoDataOutput API; it does not call AVCapturePhotoOutput.capturePhoto or manipulate system sound resources. Capture completion is shown visually. Automatic document capture also uses video frames. Normal photo mode uses AVCapturePhotoOutput and may produce the system shutter sound. Videos contain no audio; the app does not request microphone access. Document detection, perspective correction, duplicate comparison and PDF creation are local. Simulator-only sample assets are excluded from iPhoneOS builds. Settings includes an in-app privacy policy and capture-path diagnostics.

## 계정 소유자가 입력할 항목

공개 개인정보처리방침 URL, 공개 지원 URL, 개발자명·연락 이메일, 심사 담당자 연락처, 저작권 표기, 가격·판매 지역, 연령 등급 설문을 확정해야 합니다. 현재 공개 URL은 게시되지 않았습니다.

앱 개인정보 응답 초안은 ‘데이터를 수집하지 않음’입니다. 현재 코드에는 외부 전송이나 분석 SDK가 없습니다. 향후 서비스나 SDK를 추가하면 응답과 방침을 다시 검토하세요.
