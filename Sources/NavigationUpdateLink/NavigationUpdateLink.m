#import "NavigationUpdateLink.h"

PlozzCancelNavigationUpdates PlozzObserveNavigationUpdates(UIView *view, void (^action)(void)) {
    // iOS-on-Mac can satisfy the iOS deployment target without exporting this
    // class. Even a #available check around a direct class reference aborts in dyld.
    Class linkClass = NSClassFromString(@"UIUpdateLink");
    if (!linkClass) return nil;
    UIUpdateLink *link = [linkClass updateLinkForView:view actionHandler:^(UIUpdateLink *sender, UIUpdateInfo *info) {
        action();
    }];
    link.requiresContinuousUpdates = NO;
    link.enabled = YES;
    return [^{ link.enabled = NO; } copy];
}
