#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "disc_region.h"

NS_ASSUME_NONNULL_BEGIN

@interface HDMVDiscVideo : NSObject
@property(nonatomic, readonly) NSInteger playlist;
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) NSInteger chapterCount;
@end

@interface HDMVSession : NSObject
@property(nonatomic) BOOL automaticRegion;
@property(atomic) BOOL playbackPaused;
@property(nonatomic, readonly) unsigned selectedRegion;
@property(nonatomic, copy) void (^imageChanged)(UIImage * _Nullable image);
@property(nonatomic, copy) void (^selectionChanged)(NSInteger playlist, double position, NSInteger generation);
@property(nonatomic, copy, nullable) void (^playItemChanged)(NSInteger playlist, NSInteger playItem, NSString *path,
    double inTime, double outTime, double playlistStart, double position, NSInteger generation);
@property(nonatomic, copy) void (^statusChanged)(NSString *status);
@property(nonatomic, copy) void (^noticeChanged)(NSString *notice);
@property(nonatomic, copy, nullable) void (^diagnosticEvent)(NSString *event);
@property(nonatomic, copy) void (^menuVisibilityChanged)(BOOL visible);
@property(nonatomic, copy, nullable) void (^menuRequestPendingChanged)(BOOL pending);
@property(nonatomic, copy, nullable) void (^firstPlayChanged)(BOOL firstPlay);
@property(nonatomic, copy) void (^stillChanged)(BOOL active, BOOL resumePlayback);
@property(nonatomic, copy) void (^audioPIDChanged)(NSInteger pid, NSInteger generation);
@property(nonatomic, copy) void (^subtitlePIDChanged)(NSInteger pid, BOOL enabled, NSInteger generation);
- (nullable instancetype)initWithFiles:(NSDictionary<NSString *, NSNumber *> *)files
                               region:(unsigned)region
                            readRange:(NSData * _Nullable (^)(NSString *, int64_t, int64_t))readRange;
#if PLOZZ_DISC_MENU_LAB
- (nullable instancetype)initWithConfiguration:(NSURL *)configuration error:(NSError **)error;
#endif
- (void)start;
// Use a separate, unstarted session. This reads playlists without starting either disc VM.
- (void)listVideosWithCompletion:(void (^)(NSArray<HDMVDiscVideo *> * _Nullable videos,
                                         NSString * _Nullable failure))completion;
- (void)key:(unsigned)key;
- (void)clickAtX:(uint16_t)x y:(uint16_t)y NS_SWIFT_NAME(click(x:y:));
- (void)menu;
- (void)updateTime:(double)seconds generation:(NSInteger)generation;
- (void)ended:(NSInteger)generation;
- (void)selectTrackPID:(NSInteger)pid subtitle:(BOOL)subtitle generation:(NSInteger)generation
           completion:(void (^)(BOOL accepted))completion;
- (void)stop;
// NO means shutdown is still pending; the native queue retains its ownership.
- (void)drainWithCompletion:(void (^)(BOOL drained))completion NS_SWIFT_NAME(drain(completion:));
@end

NS_ASSUME_NONNULL_END
