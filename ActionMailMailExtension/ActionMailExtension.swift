import MailKit

@MainActor
final class ActionMailExtension: NSObject, MEExtension {
    func handlerForMessageActions() -> any MEMessageActionHandler {
        ActionMailMessageActionHandler()
    }
}
