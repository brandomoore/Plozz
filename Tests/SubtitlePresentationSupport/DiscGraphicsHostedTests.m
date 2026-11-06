#import <XCTest/XCTest.h>
#import "../../Sources/DiscNavigation/include/hdmv_session.h"
#include "../../Vendor/Libbluray/src/libbluray/decoders/overlay.h"
#include "../../Vendor/Libbluray/src/libbluray/bluray.h"
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
- (BLURAY *)presentationMarkDisc {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *fixtures = [[NSBundle bundleForClass:self.class].resourceURL URLByAppendingPathComponent:@"Fixtures"];
    NSURL *root = [manager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error = nil;
    XCTAssertTrue([manager copyItemAtURL:[fixtures URLByAppendingPathComponent:@"bluray-test-pattern"]
                                  toURL:root error:&error], @"%@", error);
    [self addTeardownBlock:^{
        NSError *cleanupError = nil;
        XCTAssertTrue([manager removeItemAtURL:root error:&cleanupError], @"%@", cleanupError);
    }];
    NSMutableData *playlist = [[NSData dataWithContentsOfURL:
        [fixtures URLByAppendingPathComponent:@"bdj-navigation/BDMV/PLAYLIST/00001.mpls"]] mutableCopy];
    XCTAssertNotNil(playlist);
    if (!playlist) return NULL;
    uint32_t offset;
    memcpy(&offset, (const uint8_t *)playlist.bytes + 12, 4);
    offset = CFSwapInt32BigToHost(offset);
    [playlist setLength:offset];
    uint32_t length = CFSwapInt32HostToBig(2 + 4 * 14);
    uint16_t count = CFSwapInt16HostToBig(4);
    [playlist appendBytes:&length length:4];
    [playlist appendBytes:&count length:2];
    const uint32_t seconds[] = {0, 3, 6, 8};
    for (unsigned i = 0; i < 4; i++) {
        uint8_t mark[14] = {0, 1, 0, 0};
        uint32_t time = CFSwapInt32HostToBig(seconds[i] * 45000);
        memcpy(mark + 4, &time, 4);
        mark[8] = mark[9] = 0xff;
        [playlist appendBytes:mark length:sizeof(mark)];
    }
    XCTAssertTrue([playlist writeToURL:[root URLByAppendingPathComponent:@"BDMV/PLAYLIST/00001.mpls"]
                               options:NSDataWritingAtomic error:&error], @"%@", error);
    NSData *clip = [NSData dataWithContentsOfURL:
        [fixtures URLByAppendingPathComponent:@"bdj-navigation/BDMV/CLIPINF/00001.clpi"]];
    XCTAssertTrue([clip writeToURL:[root URLByAppendingPathComponent:@"BDMV/CLIPINF/00001.clpi"]
                           options:NSDataWritingAtomic error:&error], @"%@", error);
    BLURAY *disc = bd_open(root.fileSystemRepresentation, NULL);
    XCTAssertTrue(disc != NULL);
    if (!disc) return NULL;
    [self addTeardownBlock:^{ bd_close(disc); }];
    bd_get_event(disc, NULL);
    bd_set_scr(disc, 0);
    XCTAssertEqual(bd_select_playlist(disc, 1), 1);
    return disc;
}

- (NSArray<NSNumber *> *)marksFromDisc:(BLURAY *)disc {
    NSMutableArray *marks = [NSMutableArray new];
    BD_EVENT event;
    while (bd_get_event(disc, &event)) {
        if (event.event == BD_EVENT_PLAYMARK) [marks addObject:@(event.param)];
    }
    return marks;
}

- (void)testPresentationClockDeliversMarksOnceWithoutReadingVideo {
    BLURAY *disc = [self presentationMarkDisc];
    if (!disc) return;
    XCTAssertEqualObjects([self marksFromDisc:disc], @[]);
    bd_set_scr(disc, 3 * 90000 - 1);
    XCTAssertEqualObjects([self marksFromDisc:disc], @[]);
    bd_set_scr(disc, 3 * 90000);
    XCTAssertEqualObjects([self marksFromDisc:disc], @[@1]);
    bd_set_scr(disc, 3 * 90000);
    XCTAssertEqualObjects([self marksFromDisc:disc], @[]);
    bd_set_scr(disc, -1);
    bd_set_scr(disc, 9 * 90000);
    XCTAssertEqualObjects([self marksFromDisc:disc], @[]);
    bd_set_scr(disc, 8 * 90000);
    XCTAssertEqualObjects([self marksFromDisc:disc], (@[@2, @3]));
    bd_set_scr(disc, 8 * 90000);
    XCTAssertEqualObjects([self marksFromDisc:disc], @[]);
}

- (void)testPresentationSeekSkipsPassedMarksAndRearmsOnReplay {
    BLURAY *disc = [self presentationMarkDisc];
    if (!disc) return;
    XCTAssertGreaterThanOrEqual(bd_seek_time(disc, 5 * 90000), 0);
    bd_set_scr(disc, 5 * 90000);
    XCTAssertEqualObjects([self marksFromDisc:disc], @[]);
    bd_set_scr(disc, 6 * 90000);
    XCTAssertEqualObjects([self marksFromDisc:disc], @[@2]);
    XCTAssertGreaterThanOrEqual(bd_seek_time(disc, 1 * 90000), 0);
    bd_set_scr(disc, 3 * 90000);
    XCTAssertEqualObjects([self marksFromDisc:disc], @[@1]);
    XCTAssertGreaterThanOrEqual(bd_seek_time(disc, 6 * 90000), 0);
    bd_set_scr(disc, 6 * 90000);
    XCTAssertEqualObjects([self marksFromDisc:disc], @[]);
}

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
