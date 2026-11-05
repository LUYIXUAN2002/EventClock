import SwiftUI
import UserNotifications

@main
struct EventClockApp: App {
    @State private var model = AppModel()

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
