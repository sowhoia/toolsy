import Accessibility

/// Speaks to VoiceOver users about something that appears where their focus is not: a result, a
/// confirmation, a dialog. Without VoiceOver running nothing happens.
enum VoiceOver {
    static func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
