import Foundation

/// 当前应用版本:打包后的 .app 读 Info.plist;开发运行(swift run)回落到常量。
/// 发版时同时更新这里与 git tag(vX.Y.Z),两者保持一致。
enum AppVersion {
    static let development = "0.8.0"

    static var current: String {
        // SwiftPM/XCTest can supply a host bundle version unrelated to Qili.
        guard Bundle.main.bundleIdentifier == "com.csic21.moleapp" else { return development }
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? development
    }
}
