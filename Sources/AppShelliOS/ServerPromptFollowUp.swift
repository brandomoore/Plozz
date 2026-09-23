#if os(iOS)
import CoreModels

enum ServerPromptFollowUp {
    case signIn(SyncedAccountDescriptor)
    case pairDevice(SyncedAccountDescriptor)
}
#endif
