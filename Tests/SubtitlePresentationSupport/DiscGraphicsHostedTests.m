#import <XCTest/XCTest.h>
#import "../../Sources/DiscNavigation/include/hdmv_session.h"
#include "../../Vendor/Libbluray/src/libbluray/decoders/overlay.h"
#include <mach/mach.h>

@interface HDMVSession (GraphicsTests)
- (void)argbOverlay:(const BD_ARGB_OVERLAY *)event;
@end

static uint64_t discTestFootprint(void) {
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS
        ? info.phys_footprint : 0;
}

@interface DiscGraphicsHostedTests : XCTestCase
@end

@implementation DiscGraphicsHostedTests
- (void)testJavaCallbackReleasesTemporaryFramesOnALongLivedThread {
    XCTestExpectation *finished = [self expectationWithDescription:@"Java graphics worker"];
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool {
            HDMVSession *session = [[HDMVSession alloc] initWithFiles:@{@"BDMV/index.bdmv": @40}
                region:1 readRange:^NSData *(NSString *path, int64_t offset, int64_t length) { return nil; }];
            [session setValue:[NSMutableDictionary new] forKey:@"javaPlanes"];
            const unsigned width = 960, height = 540;
            NSMutableData *source = [NSMutableData dataWithLength:width * height * 4];
            uint32_t *pixels = source.mutableBytes;
            for (unsigned i = 0; i < width * height; i++) pixels[i] = 0xff336699;
            uint64_t baseline = 0, growth = 0;
            for (unsigned frame = 0; frame < 100; frame++) {
                BD_ARGB_OVERLAY init = {.plane = 1, .cmd = BD_ARGB_OVERLAY_INIT, .w = width, .h = height};
                BD_ARGB_OVERLAY draw = {.plane = 1, .cmd = BD_ARGB_OVERLAY_DRAW,
                    .w = width, .h = height, .stride = width, .argb = pixels};
                BD_ARGB_OVERLAY flush = {.plane = 1, .cmd = BD_ARGB_OVERLAY_FLUSH};
                [session argbOverlay:&init];
                [session argbOverlay:&draw];
                [session argbOverlay:&flush];
                uint64_t footprint = discTestFootprint();
                XCTAssertGreaterThan(footprint, 0);
                if (frame == 9) baseline = footprint;
                if (frame > 9) growth = MAX(growth, footprint > baseline ? footprint - baseline : 0);
                if (growth > 128 * 1024 * 1024) break;
            }
            NSLog(@"Disc graphics repeated-frame peak growth bytes=%llu", (unsigned long long)growth);
            XCTAssertLessThan(growth, 64 * 1024 * 1024,
                              @"Java callbacks must not retain old planes until the worker thread exits.");
            [session stop];
        }
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:30];
}
@end
