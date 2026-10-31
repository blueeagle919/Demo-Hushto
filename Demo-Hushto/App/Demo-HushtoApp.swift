import SwiftUI

// Explicit property-wrapper alias keeps iOS 17 compatibility on Xcode 27.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct HushtoApp: App {
    @StateObject private var store = ScanStore()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    var body: some Scene {
        WindowGroup { HushtoRootScreen().environmentObject(store).tint(Theme.label).preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme) }
    }
}
