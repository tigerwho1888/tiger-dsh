import Foundation
import UIKit
import UserNotifications

/// Notifications for the two things that need a person: an approval, and a question waiting for an answer. The Mac
/// sends them through Apple's push service, so they arrive with the app closed and the phone locked; the local one
/// below covers a Mac without that plugin, and is skipped once the Mac has this phone's push address.
enum Notifier {
    private static let key = "notify.needsYou"
    private static let remoteKey = "notify.remote"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Turns notifications on (asking iOS once) or off; returns whether they are on afterwards.
    @discardableResult
    @MainActor
    static func set(_ on: Bool) async -> Bool {
        guard on else {
            UserDefaults.standard.set(false, forKey: key)
            UserDefaults.standard.set(false, forKey: remoteKey)
            UIApplication.shared.unregisterForRemoteNotifications()
            await DSHClient.shared.post("/tigerdsh/device-token", ["on": .bool(false)])
            return false
        }
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(ok, forKey: key)
        if ok { UIApplication.shared.registerForRemoteNotifications() }
        return ok
    }

    /// The phone's push address, from iOS: the Mac keeps it and sends to it.
    static func register(_ token: Data) {
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task {
            let taken = await DSHClient.shared.post("/tigerdsh/device-token", ["on": .bool(true), "token": .string(hex), "env": .string(env)])
            UserDefaults.standard.set(taken, forKey: remoteKey)
        }
    }

    static func needsYou(title: String, body: String, id: String, chat: String) {
        guard enabled, !UserDefaults.standard.bool(forKey: remoteKey) else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = ["sessionId": chat]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}
