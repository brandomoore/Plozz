#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HDMVSession : NSObject
@property(nonatomic, copy) void (^imageChanged)(UIImage * _Nullable image);
@property(nonatomic, copy) void (^selectionChanged)(NSInteger playlist, double position, NSInteger generation);
@property(nonatomic, copy) void (^statusChanged)(NSString *status);
@property(nonatomic, copy) void (^noticeChanged)(NSString *notice);
- (nullable instancetype)initWithConfiguration:(NSURL *)configuration error:(NSError **)error;
- (void)start;
- (void)key:(unsigned)key;
- (void)menu;
- (void)updateTime:(double)seconds generation:(NSInteger)generation;
- (void)ended:(NSInteger)generation;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
