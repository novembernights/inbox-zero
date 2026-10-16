import MailKit

/// A deliberately passive MailKit bridge. It receives message events but never
/// classifies, colors, moves, flags, or blocks mail.
final class ActionMailMessageActionHandler: NSObject, MEMessageActionHandler {
    var requiredHeaders: [String] { [] }

    func decideAction(
        for message: MEMessage,
        completionHandler: @escaping (MEMessageActionDecision?) -> Void
    ) {
        completionHandler(nil)
    }
}
