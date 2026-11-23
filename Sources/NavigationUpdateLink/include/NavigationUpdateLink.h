#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns a cancellation block, or nil when the host UIKit has no update link.
typedef void (^PlozzCancelNavigationUpdates)(void);
UIKIT_EXTERN NS_SWIFT_UI_ACTOR PlozzCancelNavigationUpdates _Nullable
PlozzObserveNavigationUpdates(UIView *view, void (^action)(void));

NS_ASSUME_NONNULL_END
