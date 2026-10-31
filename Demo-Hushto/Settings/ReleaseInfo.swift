import SwiftUI

struct PrivacyPolicyScreen: View {
    var body: some View {
        List {
            Section("개인정보처리방침 · 2026년 10월 9일") {
                Text("Demo-Hushto는 계정, 광고, 분석 SDK 없이 동작하는 오프라인 문서 스캔 앱입니다. 앱이 운영하는 서버로 사진, 문서, 설정 또는 기기 정보를 전송하지 않습니다.")
            }
            Section("카메라와 사진 권한") {
                Text("카메라는 사용자가 요청한 사진·문서 촬영 및 소리를 포함한 영상 녹화에 사용합니다. 촬영 화면과 완료 표시를 제공합니다. 카메라 권한은 iOS 설정에서 변경할 수 있습니다.")
                Text("사진 가져오기는 iOS 사진 선택기를 사용하여 사용자가 선택한 항목만 읽습니다. 사진·동영상 촬영 후 자동 저장하거나 스캔 페이지의 ‘사진 앱에 저장’을 누를 때 사진 추가 권한을 요청합니다. 동영상 녹화 시 소리를 함께 기록하기 위해 마이크 권한을 요청합니다. 위치와 연락처 권한은 요청하지 않습니다.")
            }
            Section("저장과 삭제") {
                Text("문서·칠판·스크린 스캔의 원본, 보정 이미지, 페이지 순서와 PDF는 앱의 문서 폴더에 저장합니다. 사진·동영상 모드의 촬영본은 사진 앱에 바로 저장하며 PDF 스캔 세션에 넣지 않습니다. 동영상은 사진 앱으로 저장하는 동안 임시 파일을 사용하고 완료 화면을 닫을 때 임시 파일을 삭제합니다. 기본 모드 등의 설정은 앱의 UserDefaults에 저장합니다.")
                Text("촬영 페이지는 페이지 관리에서 삭제할 수 있습니다. 저장 파일은 설정의 저장한 PDF·동영상에서 삭제하거나 파일 앱에서 관리할 수 있습니다. 앱을 삭제하면 앱 내부 데이터가 삭제됩니다. 사진 앱 또는 외부에 내보낸 사본과 시스템 백업은 별도로 삭제해야 합니다.")
                Text("iOS 기기 백업 및 사용자가 파일 앱에서 선택한 iCloud·외부 저장 서비스에는 해당 시스템·서비스의 정책과 설정이 적용됩니다.")
            }
            Section("외부 공유") {
                Text("공유 버튼을 누르면 iOS 공유 시트가 열립니다. 사용자가 선택한 파일과 받는 앱·서비스에만 공유하며, 공유 이후에는 받는 서비스의 개인정보처리방침이 적용됩니다.")
            }
            Section("추적과 진단") {
                Text("광고 식별자, 위치, 광고 추적 또는 사용자 프로파일링을 사용하지 않습니다. 페이지 중복 확인용 이미지 밝기 정보는 기기에서 문서 비교에만 사용합니다.")
                Text("촬영 방식 확인 화면의 진단 정보는 메모리에만 유지됩니다. 진단 공유를 누르면 앱 버전, iOS 버전, 촬영 경로·해상도·횟수만 공유 시트에 전달합니다. 사진 내용이나 기기 고유 식별자는 포함하지 않습니다.")
            }
        }.navigationTitle("개인정보처리방침").navigationBarTitleDisplayMode(.inline)
    }
}
struct SupportScreen: View {
    var body: some View {
        List {
            Section("촬영이 안 될 때") {
                Text("iOS 설정 → Demo-Hushto → 카메라 권한을 확인해주세요. 다른 카메라 앱을 닫고 다시 시도해주세요.")
                Text("시뮬레이터는 실제 카메라가 없어서 샘플 프레임을 사용합니다. 실제 촬영과 촬영음은 iPhone에서 확인해야 합니다.")
            }
            Section("문서가 흐릴 때") {
                Text("밝은 곳에서 문서를 화면 안에 충분히 크게 맞추고 기기를 고정해주세요. 무음 모드는 공식 무음 사진 촬영 지원 여부에 따라 최대 사진 크기 또는 최대 네이티브 영상 프레임을 저장합니다. 실제 해상도는 설정의 촬영 방식 확인에서 확인해주세요. 작은 글씨는 문서에 가까이 다가가 촬영해주세요.")
            }
            Section("저장과 PDF") {
                Text("페이지 관리에서 순서를 변경하고 PDF 만들기를 선택하세요. 동일한 이름의 PDF가 있으면 다른 이름을 입력해주세요. 저장 오류가 발생하면 기기 저장 공간을 확인해주세요.")
                Text("파일 앱 → 나의 iPhone → Demo-Hushto에서도 파일을 관리할 수 있습니다. 앱 안에서 파일을 삭제해도 이미 공유한 사본은 유지됩니다.")
            }
            Section("문의") {
                if let email = Bundle.main.object(forInfoDictionaryKey: "HushtoSupportEmail") as? String,
                   let url = URL(string: "mailto:" + email) {
                    Link("개발자에게 문의", destination: url)
                } else {
                    Text("문제를 보고할 때 앱 버전, iPhone 모델, iOS 버전과 재현 단계를 함께 알려주세요. 문서 사진에는 개인정보가 있을 수 있으므로 필요하지 않은 사진은 보내지 마세요.")
                }
            }
        }.navigationTitle("도움말·고객지원").navigationBarTitleDisplayMode(.inline)
    }
}
struct CaptureDiagnosticsScreen: View {
    @ObservedObject var camera: CameraController
    @ViewState private var share = false
    private var diagnosticText: String {
        "Demo-Hushto 1.0.0\niOS \(UIDevice.current.systemVersion)\n마지막 촬영: \(camera.lastCaptureMethod)\n해상도: \(camera.lastCapturePixels)\n영상 프레임 저장: \(camera.silentFrameCount)회\n공식 무음 사진: \(camera.silentPhotoCount)회\n시스템 사진 요청: \(camera.systemPhotoCount)회\n이 정보는 실제 소리 측정 결과가 아닙니다."
    }
    var body: some View {
        List {
            Section("이번 앱 실행의 촬영 경로") {
                LabeledContent("마지막 촬영", value: camera.lastCaptureMethod)
                LabeledContent("해상도", value: camera.lastCapturePixels)
                LabeledContent("영상 프레임 저장", value: "\(camera.silentFrameCount)회")
                LabeledContent("공식 무음 사진", value: "\(camera.silentPhotoCount)회")
                LabeledContent("시스템 사진 요청", value: "\(camera.systemPhotoCount)회")
            }
            Section {
                Text("무음 촬영 후 영상 프레임 저장 횟수가 증가하고 시스템 사진 요청 횟수가 증가하지 않는지 확인하세요. 자동 촬영도 영상 프레임을 사용합니다.")
                Text("이 정보는 코드 경로 확인용입니다. 실제 촬영음은 다른 기기에서 듣거나 녹음하여 별도로 확인해야 합니다. 앱을 종료하면 진단 횟수는 초기화됩니다.")
                Button("진단 정보 공유") { share = true }
            }
        }.navigationTitle("촬영 방식 확인").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $share) { ShareSheet(items: [diagnosticText]) }
    }
}
