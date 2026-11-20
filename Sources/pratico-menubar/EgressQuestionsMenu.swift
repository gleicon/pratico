import AppKit
import PraticoCore
import SwiftUI
import UserNotifications

/// `GET /pratico/egress/questions`: destinations ask-mode containers wait on (D-62).
struct EgressQuestion: Decodable, Equatable, Identifiable, Sendable {
    var Id: String
    var Container: String
    var ContainerName: String
    var Destination: String
    var Port: Int
    var Asked: String
    var id: String { Id }

    var title: String { "\(ContainerName) wants to reach \(Destination)" + (Port == 53 ? "" : ":\(Port)") }
}

/// The answers, as the daemon takes them.
enum EgressAnswer: String, CaseIterable {
    case allow, always, deny

    var title: String {
        switch self {
        case .allow: "Allow"
        case .always: "Always Allow"
        case .deny: "Deny"
        }
    }

    /// Sends the answer; false when the question is gone (answered, or it timed out).
    @discardableResult
    nonisolated static func send(_ answer: EgressAnswer, to id: String) -> Bool {
        DaemonProbe.request("POST", "/pratico/egress/questions/\(id)?answer=\(answer.rawValue)", timeout: 5)?.status == 204
    }
}

/// Questions as notifications with the answers as their actions, so a held connection can
/// be answered without opening the menu. Shown even while the menu is in front.
final class EgressQuestionNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = EgressQuestionNotifier()
    static let category = "dev.pratico.egress.question"

    /// Registers the actions; the delegate is the app's for its whole run.
    func install() {
        let center = UNUserNotificationCenter.current()
        let actions = EgressAnswer.allCases.map { a in
            UNNotificationAction(identifier: a.rawValue, title: a.title, options: a == .deny ? [.destructive] : [])
        }
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: actions, intentIdentifiers: [])])
        center.delegate = self
    }

    func post(_ q: EgressQuestion) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Pratico: \(q.title)"
            content.body = "Held until you answer, refused in 30 s. Allow lets it through while \(q.ContainerName) runs; Always Allow adds it to its allowlist."
            content.categoryIdentifier = Self.category
            content.userInfo = ["question": q.Id]
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: q.Id, content: content, trigger: nil))
        }
    }

    /// A question no longer waiting (answered here or elsewhere, or timed out).
    func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["question"] as? String,
            let answer = EgressAnswer(rawValue: response.actionIdentifier)
        else { return }
        EgressAnswer.send(answer, to: id)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// The menu's own place for the same questions, for when notifications are off.
struct EgressQuestionsMenu: View {
    let daemon: DaemonController

    var body: some View {
        if !daemon.questions.isEmpty {
            Section("Waiting for You") {
                ForEach(daemon.questions) { q in
                    Menu(q.title) {
                        ForEach(EgressAnswer.allCases, id: \.self) { a in
                            Button(a.title) { daemon.answer(q, a) }
                        }
                    }
                }
            }
            Divider()
        }
    }
}
