#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "disc_region.h"

NS_ASSUME_NONNULL_BEGIN

@interface HDMVSession : NSObject
@property(nonatomic) BOOL automaticRegion;
@property(nonatomic, readonly) unsigned selectedRegion;
@property(nonatomic, copy) void (^imageChanged)(UIImage * _Nullable image);
@property(nonatomic, copy) void (^selectionChanged)(NSInteger playlist, double position, NSInteger generation);
@property(nonatomic, copy) void (^statusChanged)(NSString *status);
@property(nonatomic, copy) void (^noticeChanged)(NSString *notice);
@property(nonatomic, copy) void (^menuVisibilityChanged)(BOOL visible);
- (nullable instancetype)initWithFiles:(NSDictionary<NSString *, NSNumber *> *)files
                               region:(unsigned)region
                            readRange:(NSData * _Nullable (^)(NSString *, int64_t, int64_t))readRange;
#if PLOZZ_DISC_MENU_LAB
- (nullable instancetype)initWithConfiguration:(NSURL *)configuration error:(NSError **)error;
#endif
- (void)start;
- (void)key:(unsigned)key;
- (void)menu;
- (void)updateTime:(double)seconds generation:(NSInteger)generation;
- (void)ended:(NSInteger)generation;
- (void)stop;
- (void)drainWithCompletion:(void (^)(void))completion NS_SWIFT_NAME(drain(completion:));
@end

NS_ASSUME_NONNULL_END
