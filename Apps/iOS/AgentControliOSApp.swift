import AgentCompanion
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

@main
struct AgentControliOSApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @StateObject private var model = CompanionAppModel()

    var body: some Scene {
        WindowGroup {
            CompanionRootView(model: model)
                .onOpenURL { model.open($0) }
                .task {
                    appDelegate.model = model
                    await model.start()
                    await appDelegate.deliverDeferredActionIfNeeded()
                }
        }
    }
}

final class CompanionAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor weak var model: CompanionAppModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(CompanionNotificationActions.categories)
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { await model?.registerPushToken(token) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = DeferredNotificationAction(response: response)
        guard let model = await MainActor.run(body: { self.model }) else {
            action.save()
            return
        }
        await model.handle(action)
    }

    @MainActor
    func deliverDeferredActionIfNeeded() async {
        guard let model, let action = DeferredNotificationAction.restore() else { return }
        await model.handle(action)
        DeferredNotificationAction.clear()
    }
}

enum CompanionNotificationActions {
    static let approve = "APPROVE"
    static let deny = "DENY"
    static let review = "REVIEW"
    static let openMac = "OPEN_MAC"
    static let answer = "ANSWER"

    static var categories: Set<UNNotificationCategory> {
        let approveAction = UNNotificationAction(
            identifier: approve,
            title: String(localized: "notification.approve"),
            options: [.authenticationRequired]
        )
        let denyAction = UNNotificationAction(
            identifier: deny,
            title: String(localized: "notification.deny"),
            options: [.authenticationRequired, .destructive]
        )
        let reviewAction = UNNotificationAction(
            identifier: review,
            title: String(localized: "notification.review"),
            options: [.foreground]
        )
        let openMacAction = UNNotificationAction(
            identifier: openMac,
            title: String(localized: "notification.openMac"),
            options: [.foreground]
        )
        let answerAction = UNTextInputNotificationAction(
            identifier: answer,
            title: String(localized: "notification.answer"),
            options: [.authenticationRequired],
            textInputButtonTitle: String(localized: "notification.send"),
            textInputPlaceholder: String(localized: "notification.answerPlaceholder")
        )
        return [
            UNNotificationCategory(
                identifier: CompanionNotificationCategory.lowApproval,
                actions: [approveAction, denyAction], intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: CompanionNotificationCategory.mediumApproval,
                actions: [approveAction, denyAction], intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: CompanionNotificationCategory.highApproval,
                actions: [reviewAction, denyAction], intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: CompanionNotificationCategory.criticalApproval,
                actions: [openMacAction, denyAction], intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: CompanionNotificationCategory.question,
                actions: [answerAction, reviewAction, denyAction], intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: CompanionNotificationCategory.questionReview,
                actions: [reviewAction, denyAction], intentIdentifiers: []
            )
        ]
    }
}

struct DeferredNotificationAction: Codable, Sendable {
    let identifier: String
    let itemData: Data?
    let answer: String?

    init(response: UNNotificationResponse) {
        identifier = response.actionIdentifier
        if let encoded = response.notification.request.content.userInfo["companion_item"] as? String {
            itemData = Data(base64Encoded: encoded)
        } else {
            itemData = nil
        }
        answer = (response as? UNTextInputNotificationResponse)?.userText
    }

    private static let key = "deferred-notification-action-v1"

    func save() {
        UserDefaults(suiteName: CompanionRuntimeConfiguration.appGroupID)?
            .set(try? CompanionCoding.makeEncoder().encode(self), forKey: Self.key)
    }

    static func restore() -> Self? {
        guard let data = UserDefaults(suiteName: CompanionRuntimeConfiguration.appGroupID)?.data(forKey: key) else {
            return nil
        }
        return try? CompanionCoding.makeDecoder().decode(Self.self, from: data)
    }

    static func clear() {
        UserDefaults(suiteName: CompanionRuntimeConfiguration.appGroupID)?.removeObject(forKey: key)
    }
}
