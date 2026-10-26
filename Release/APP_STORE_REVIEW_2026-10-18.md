# Hushto App Store 배포 검토 — 2026-10-18

결론: App Store 심사를 준비할 수 있는 앱 구조이나, 현재 바로 제출 가능한 상태로 확인되지는 않았습니다. 승인 여부는 Apple 심사에서 결정됩니다. 이번 작업은 소스 수정·검토이며 App Store Connect 업로드나 제출을 수행하지 않았습니다.

## 이번 요청에 따른 변경

- 설정의 Hushto 버전 행은 정보로만 표시하고 앱 설명 상세 화면을 제거했습니다.
- 개인정보처리방침·도움말·고객지원·촬영 방식 안내를 각각 공개 문서로 연결했습니다. 내부 체크리스트는 연결하지 않았습니다.
- 제공된 app.notion.com 주소의 실제 공개 리디렉션을 확인하고, 중간 안내 화면을 생략하는 아래 notion.site 주소를 앱에 적용했습니다.
- 실제 카메라 줌 배율이 1을 넘으면 기존 상태 배지에 배율을 표시합니다. 1배 이하에서는 기존 안내를 표시합니다. 접근 거절·카메라 준비/사용 불가 안내는 우선합니다.
- 실제 카메라 장치에 배율이 적용된 후 UI에 전달하며, 카메라 전환/재설정 시 현재 장치 배율로 동기화합니다.
- 촬영·저장·보정·토글·선택기 등 다른 기능은 변경하지 않았습니다.

## 공개 링크 확인

| 문서 | 앱에 연결한 직접 주소 | 확인 |
| --- | --- | --- |
| 개인정보처리방침 | https://even-kale-201.notion.site/Hushto-3fa582c1e59681728478c1bc9596cc6d | 로그인 과정 없이 본문 확인, 375×812 화면 확인 |
| 도움말 | https://even-kale-201.notion.site/Hushto-3fa582c1e5968103b383f84a100f916d | 로그인 과정 없이 본문·문의 링크 확인, 모바일 폭에서 확인 |
| 고객지원 | https://even-kale-201.notion.site/Hushto-3fb582c1e596815b8cb7d4eb3a3477cc | 로그인 과정 없이 본문·이메일·문의 양식 링크 확인, 모바일 폭에서 확인 |
| 촬영 방식 안내 | https://even-kale-201.notion.site/Hushto-3fa582c1e596810eb671fb459dcb86c1 | 로그인 과정 없이 공개 페이지 확인, 375×812 본문 확인 |

공개 Notion 화면은 모바일에서 좌우 여백이 커서 본문 폭이 좁고 줄바꿈이 많았습니다. 외부 문서 디자인은 이번 앱 수정 범위 밖이므로 변경하지 않았습니다. 문의 양식 제출, 이메일 발송, 문서 공개 범위 변경은 하지 않았습니다.

## 소스 검토 결과

- 촬영은 공개 AVFoundation API를 사용합니다. iOS 18 이상에서 공식 셔터음 억제를 지원하는 경우만 해당 설정을 켜며, 미지원 시 영상 프레임으로 저장합니다. 시스템 음원 삭제·사설 API 호출·벨소리 스위치 변경 코드는 이번 정적 검색에서 발견되지 않았습니다.
- 카메라·사진 추가 권한 설명이 Info.plist에 있습니다. 마이크 입력을 추가하지 않으며 동영상은 오디오 없이 녹화합니다.
- PrivacyInfo.xcprivacy에 UserDefaults CA92.1, 부팅 이후 시간 35F9.1, 추적 없음이 선언되어 있습니다.
- 앱 소스에서 분석·광고 SDK나 URLSession을 통한 문서 업로드 코드는 발견되지 않았습니다. 이는 정적 검토이며 실기기 네트워크 관찰을 대체하지 않습니다.
- 앱 아이콘 자산과 iOS 17 최소 버전 설정이 있습니다.
- 로컬 이미지 처리·스캔 관리·PDF 출력 기능은 웹 문서 링크와 별도로 구현돼 있습니다.

## 제출 전 해결할 항목

1. **배포 서명과 계정:** 현재 서명 빌드는 `app.hushto.scanner`용 iOS App Development 프로비저닝 프로파일을 찾지 못해 실패했습니다. 이는 소스 컴파일 오류와 구분됩니다. Apple Developer 계정/멤버십, 앱 식별자, 배포 인증서·프로파일을 확인한 후 Archive의 Distribute App 검증을 완료해야 합니다. App Store용 서명·IPA·업로드는 미검증입니다.
2. **스토어 문안 갱신:** 기존 `Release/APP_STORE_METADATA.md`에는 720p 고정, 무음 시 사진 API 미사용, 공개 URL 미게시 등 현재 구현과 다른 설명이 남아 있습니다. 최대 네이티브 해상도/기기별 공식 무음 사진 경로, 사진·동영상 자동 사진 앱 저장, 공개 정책·지원 URL을 반영해야 합니다. 이 파일은 이번 요청의 앱 변경 범위 밖이므로 수정하지 않았습니다.
3. **개인정보 응답:** 기기 내 처리만으로 무조건 ‘수집 없음’을 확정하지 마세요. 고객지원 Google Form·이메일은 사용자가 제출한 내용과 이메일 등을 처리합니다. Apple의 선택적 고객지원 수집 공개 예외 조건 전체를 대조하고, 해당하지 않는 데이터는 App Store Connect에 신고해야 합니다. 공개 방침에도 이 수집·보관 정보가 기재되어 있습니다.
4. **문서와 실제 동작 일치:** 공개 문서의 마이크 관련 조건부 표현은 현재 오디오 없는 동영상 구현보다 포괄적입니다. 사진·동영상 자동 저장과 PDF 실제 저장 위치, 삭제/외부 사본 유지 설명도 출시 동작과 최종 대조하세요. 개인정보 방침의 시행일이 공개 화면에서 상대 날짜로 표시되는 점도 고정 날짜 표기를 검토할 수 있습니다.
5. **실기기/TestFlight 확인:** iPhone 13 mini 등에서 실행·권한 거절/허용·갤러리 자동 저장·자동 스캔·PDF 생성/공유·1배 복귀·전후면 전환·모든 모드의 줌 배지와 링크를 확인해야 합니다. 실제 센서 줌과 촬영음은 시뮬레이터나 규칙 테스트로 확인할 수 없습니다.
6. **App Store Connect:** 개인정보처리방침 URL, 지원 URL, 스크린샷, 정확한 설명/심사 메모, 연령 등급, 연락처, 판매 지역 등 입력 및 검토가 필요합니다. 현재 계정의 설정 완료 여부는 확인하지 않았습니다.

## 근거

- [Apple App Review Guidelines — 2.1, 2.3, 2.5.1, 2.5.14, 5.1.1](https://developer.apple.com/app-store/review/guidelines/)
- [공식 셔터음 억제 지원 API](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isshuttersoundsuppressionsupported)
- [App Store 개인정보 공개 및 선택적 고객지원 수집 예외](https://developer.apple.com/app-store/app-privacy-details/)
- [App Store Connect 개인정보 URL 항목](https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy/)
- 사용자 제공 내부 체크리스트를 Notion 연결 도구로 확인했습니다. 기록에 문서 게시 완료와 과거 초안 상태가 함께 있어, 공개 여부는 현재 브라우저 접근 결과를 기준으로 판단했습니다.

## 이번 실행 검증과 제한

- 줌 배지: 1배 이하 숨김, 1.5x·2.0x 포맷, NaN/무한값 제외 규칙 검사 통과.
- 기존 핀치 배율·상한/하한, 자동 스캔 안정성, 정확한 프레임 시간, 고해상도 선택, 파일명·중복·무음 라우팅 회귀 검사 통과.
- iPhoneOS Release 소스 빌드: 배포 서명 없이 통과. 공개 URL 직접 연결 후 최종 증분 빌드 결과는 아래에 기록합니다.
- 서명 빌드: 프로비저닝 프로파일 미확보로 실패. 자동 프로파일 생성·계정 변경은 수행하지 않았습니다.
- 시뮬레이터 출시 구성 검수: Device Hub가 Connecting display / Connection timed out를 표시하여 앱 내 링크 터치 확인을 완료하지 못했습니다. 검수를 위해 부팅한 시뮬레이터는 다시 종료했고, 시뮬레이터 빌드는 중단했습니다. 이것을 앱 실행 성공으로 기록하지 않습니다.
- 실제 iPhone에는 설치하지 않았습니다. 실기기 핀치·저장·링크 검수 및 TestFlight 배포 검증이 남아 있습니다.
- 로그: 이 대화 작업 폴더의 `work/release-links-zoom-build.log`, `work/release-links-zoom-unsigned.log`, `work/release-links-zoom-final.log`, `work/release-links-zoom-simulator.log`.

최종 결과: 공개 notion.site 직접 URL을 반영한 iPhoneOS Release 증분 빌드도 `BUILD SUCCEEDED`로 완료했습니다 (`CODE_SIGNING_ALLOWED=NO`).
