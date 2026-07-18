import Foundation
import Sparkle

@MainActor
final class SparkleUpdateController {
    let isConfigured: Bool
    private let controller: SPUStandardUpdaterController

    init(bundle: Bundle = .main) {
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let keyData = publicKey.flatMap { Data(base64Encoded: $0) }
        isConfigured = feedURL.flatMap(URL.init(string:))?.scheme == "https" && keyData?.count == 32
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }
}
