#import <XCTest/XCTest.h>
#import "../../Sources/DiscNavigation/include/hdmv_session.h"
#include "../../Vendor/Libbluray/src/libbluray/decoders/overlay.h"
#include "../../Vendor/Libbluray/src/libbluray/bluray.h"
#include <mach/mach.h>
#include <sys/resource.h>

@interface HDMVSession (GraphicsTests)
- (void)argbOverlay:(const BD_ARGB_OVERLAY *)event;
@end

static uint64_t discTestFootprint(void) {
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS
        ? info.phys_footprint : 0;
}

static uint64_t discTestResidentBytes(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    return task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS
        ? info.resident_size : 0;
}

static uint32_t discTestFirstPixel(UIImage *image) {
    uint32_t pixel = 0;
    CGImageRef crop = CGImageCreateWithImageInRect(image.CGImage, CGRectMake(0, 0, 1, 1));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(&pixel, 1, 1, 8, 4, space,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context && crop) CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), crop);
    if (context) CGContextRelease(context);
    if (crop) CGImageRelease(crop);
    CGColorSpaceRelease(space);
    return pixel;
}

@interface DiscGraphicsHostedTests : XCTestCase
@end

@implementation DiscGraphicsHostedTests
- (void)testNativeBuildRejectsJavaMenusWithoutReadingCodeButStillListsVideos {
    XCTSkipIf(HDMVSession.supportsJavaMenus, @"Native-only build regression.");
    NSURL *fixtures = [[NSBundle bundleForClass:self.class].resourceURL URLByAppendingPathComponent:@"Fixtures"];
    NSURL *navigation = [fixtures URLByAppendingPathComponent:@"bdj-navigation"];
    NSMutableDictionary<NSString *, NSData *> *contents = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:navigation
        includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:0 errorHandler:nil];
    for (NSURL *file in enumerator) {
        NSNumber *regular = nil;
        [file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!regular.boolValue) continue;
        NSString *relative = [file.path substringFromIndex:navigation.path.length + 1];
        NSData *data = [NSData dataWithContentsOfURL:file];
        XCTAssertNotNil(data);
        contents[relative] = data;
    }
    for (NSString *clip in @[@"00001", @"00002"]) {
        NSString *path = [NSString stringWithFormat:@"BDMV/STREAM/%@.m2ts", clip];
        NSData *data = [NSData dataWithContentsOfURL:
            [fixtures URLByAppendingPathComponent:[@"bluray-test-pattern/" stringByAppendingString:path]]];
        XCTAssertNotNil(data);
        contents[path] = data;
    }
    NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
    for (NSString *path in contents) sizes[path] = @(contents[path].length);
    NSMutableSet<NSString *> *reads = [NSMutableSet set];
    NSData *(^reader)(NSString *, int64_t, int64_t) = ^NSData *(NSString *path, int64_t offset, int64_t length) {
        @synchronized (reads) { [reads addObject:path]; }
        NSData *data = contents[path];
        if (!data || offset < 0 || length < 0 || offset > data.length || length > data.length - offset) return nil;
        return [data subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)length)];
    };
    HDMVSession *menu = [[HDMVSession alloc] initWithFiles:sizes region:1 readRange:reader];
    XCTAssertNotNil(menu);
    XCTestExpectation *rejected = [self expectationWithDescription:@"Java menu rejected before playback"];
    menu.statusChanged = ^(NSString *status) {
        XCTAssertEqualObjects(status, @"This disc's menu format is not supported");
        [rejected fulfill];
    };
    menu.selectionChanged = ^(NSInteger playlist, double position, NSInteger generation) {
        XCTFail(@"Unsupported Java menu must not start background video");
    };
    [self addTeardownBlock:^{ [menu stop]; }];
    [menu start];
    [self waitForExpectations:@[rejected] timeout:10];
    HDMVSession *catalog = [[HDMVSession alloc] initWithFiles:sizes region:1 readRange:reader];
    [self addTeardownBlock:^{ [catalog stop]; }];
    XCTestExpectation *listed = [self expectationWithDescription:@"Java disc retains direct title access"];
    [catalog listVideosWithCompletion:^(NSArray<HDMVDiscVideo *> *videos, NSString *failure) {
        XCTAssertNil(failure);
        XCTAssertEqual(videos.count, 2);
        [listed fulfill];
    }];
    [self waitForExpectations:@[listed] timeout:10];
    @synchronized (reads) {
        for (NSString *path in reads) {
            XCTAssertFalse([path containsString:@"/JAR/"]);
            XCTAssertFalse([path containsString:@"/BDJO/"]);
        }
    }
}

- (void)testStoppingDropsQueuedGraphicsAndRepeatedStopDrains {
    HDMVSession *session = [self graphicsSession];
    __block BOOL published = NO;
    session.imageChanged = ^(UIImage *image) { published = YES; };
    session.menuVisibilityChanged = ^(BOOL visible) { published = YES; };
    uint32_t pixel = 0xff336699;
    BD_ARGB_OVERLAY init = {.plane = 1, .cmd = BD_ARGB_OVERLAY_INIT, .w = 1, .h = 1};
    BD_ARGB_OVERLAY draw = {.plane = 1, .cmd = BD_ARGB_OVERLAY_DRAW,
        .w = 1, .h = 1, .stride = 1, .argb = &pixel};
    BD_ARGB_OVERLAY flush = {.plane = 1, .cmd = BD_ARGB_OVERLAY_FLUSH};
    [session argbOverlay:&init];
    [session argbOverlay:&draw];
    [session argbOverlay:&flush];
    [session stop];
    [session stop];
    [session argbOverlay:&draw];
    [session argbOverlay:&flush];
    XCTestExpectation *finished = [self expectationWithDescription:@"Repeated stop drains"];
    [session drainWithCompletion:^(BOOL drained) {
        XCTAssertTrue(drained);
        dispatch_async(dispatch_get_main_queue(), ^{ [finished fulfill]; });
    }];
    [self waitForExpectations:@[finished] timeout:6];
    XCTAssertFalse(published);
    XCTAssertNil([session valueForKey:@"javaFrame"]);
}

- (HDMVSession *)graphicsSession {
    HDMVSession *session = [[HDMVSession alloc] initWithFiles:@{@"BDMV/index.bdmv": @40}
        region:1 readRange:^NSData *(NSString *path, int64_t offset, int64_t length) { return nil; }];
    [session setValue:[NSMutableDictionary new] forKey:@"javaPlanes"];
    [self addTeardownBlock:^{ [session stop]; }];
    return session;
}

- (void)testPerformanceJavaRepeatedFlushes {
    XCTSkipIf(![NSProcessInfo.processInfo.environment[@"PLOZZ_PERFORMANCE"] isEqualToString:@"1"],
              @"Opt-in simulator workload; use tools/performance.py.");
#if !TARGET_OS_SIMULATOR
    XCTSkip(@"Simulator-only performance workload");
#endif
    NSMutableArray *samples = [NSMutableArray new];
    for (NSInteger iteration = -1; iteration < 5; iteration++) {
        @autoreleasepool {
            HDMVSession *session = [self graphicsSession];
            const unsigned width = 960, height = 540, frames = 200;
            NSMutableData *source = [NSMutableData dataWithLength:width * height * 4];
            uint32_t *pixels = source.mutableBytes;
            for (unsigned index = 0; index < width * height; index++) pixels[index] = 0xff336699;
            BD_ARGB_OVERLAY init = {.plane = 1, .cmd = BD_ARGB_OVERLAY_INIT, .w = width, .h = height};
            BD_ARGB_OVERLAY draw = {.plane = 1, .cmd = BD_ARGB_OVERLAY_DRAW,
                .w = width, .h = height, .stride = width, .argb = pixels};
            BD_ARGB_OVERLAY flush = {.plane = 1, .cmd = BD_ARGB_OVERLAY_FLUSH};
            [session argbOverlay:&init];
            struct rusage before, after;
            XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0);
            uint64_t memory = discTestResidentBytes();
            NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
            for (unsigned frame = 0; frame < frames; frame++) {
                if (frame % 10 == 0) {
                    uint32_t color = pixels[0] ^ 0x00ffffff;
                    for (unsigned index = 0; index < width * height; index++) pixels[index] = color;
                }
                [session argbOverlay:&draw];
                [session argbOverlay:&flush];
                if (frame % 10 == 0)
                    XCTAssertEqual(discTestFirstPixel([session valueForKey:@"javaFrame"]), pixels[0]);
            }
            NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - start;
            XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0);
            uint64_t finalMemory = discTestResidentBytes();
            XCTAssertGreaterThan(memory, 0);
            XCTAssertGreaterThan(finalMemory, 0);
            XCTAssertNotNil([session valueForKey:@"javaFrame"]);
            if (iteration >= 0) {
                double cpu = (after.ru_utime.tv_sec + after.ru_stime.tv_sec
                    - before.ru_utime.tv_sec - before.ru_stime.tv_sec) * 1000.0
                    + (after.ru_utime.tv_usec + after.ru_stime.tv_usec
                    - before.ru_utime.tv_usec - before.ru_stime.tv_usec) / 1000.0;
                [samples addObject:@{@"iteration": @(iteration), @"wallMilliseconds": @(elapsed * 1000),
                    @"cpuMilliseconds": @(cpu), @"residentBytes": @(finalMemory),
                    @"residentDeltaBytes": @((int64_t)finalMemory - (int64_t)memory),
                    @"counters": @{@"frames": @(frames), @"changedFrames": @20, @"pixelsPerFrame": @(width * height)}}];
            }
            [session stop];
        }
    }
    NSError *error = nil;
    NSData *report = [NSJSONSerialization dataWithJSONObject:
        @{@"schema": @1, @"scenario": @"disc-java-flush", @"warmups": @1, @"samples": samples}
        options:0 error:&error];
    XCTAssertNotNil(report, @"%@", error);
    XCTAttachment *attachment = [XCTAttachment attachmentWithData:report uniformTypeIdentifier:@"public.json"];
    attachment.name = @"plozz-performance-disc-java-flush.json";
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}

- (void)testJavaPlaneChangesClearCloseAndOrdering {
    HDMVSession *session = [self graphicsSession];
    uint32_t colors[] = {0xffff0000, 0xff00ff00, 0xff0000ff};
    for (unsigned plane = 0; plane < 3; plane++) {
        BD_ARGB_OVERLAY init = {.plane = plane, .cmd = BD_ARGB_OVERLAY_INIT, .w = 1, .h = 1};
        BD_ARGB_OVERLAY draw = {.plane = plane, .cmd = BD_ARGB_OVERLAY_DRAW,
            .w = 1, .h = 1, .stride = 1, .argb = &colors[plane]};
        BD_ARGB_OVERLAY flush = {.plane = plane, .cmd = BD_ARGB_OVERLAY_FLUSH};
        [session argbOverlay:&init];
        [session argbOverlay:&draw];
        [session argbOverlay:&flush];
    }
    UIImage *image = [session valueForKey:@"javaFrame"];
    BD_ARGB_OVERLAY unchangedDraw = {.plane = 1, .cmd = BD_ARGB_OVERLAY_DRAW,
        .w = 1, .h = 1, .stride = 1, .argb = &colors[1]};
    BD_ARGB_OVERLAY unchangedFlush = {.plane = 1, .cmd = BD_ARGB_OVERLAY_FLUSH};
    [session argbOverlay:&unchangedDraw];
    [session argbOverlay:&unchangedFlush];
    XCTAssertEqual([session valueForKey:@"javaFrame"], image,
                   @"Identical drawing and flushing must reuse the composed frame");
    BD_ARGB_OVERLAY reset = {.plane = 1, .cmd = BD_ARGB_OVERLAY_INIT, .w = 1, .h = 1};
    [session argbOverlay:&reset];
    [session argbOverlay:&unchangedFlush];
    XCTAssertEqual(discTestFirstPixel([session valueForKey:@"javaFrame"]), colors[0]);
    [session argbOverlay:&unchangedDraw];
    [session argbOverlay:&unchangedFlush];
    image = [session valueForKey:@"javaFrame"];
    uint32_t pixel = 0;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(&pixel, 1, 1, 8, 4, space,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    XCTAssertEqual(pixel, colors[1], @"Plane 1 must remain above planes 0 and 2");
    BD_ARGB_OVERLAY close = {.plane = 1, .cmd = BD_ARGB_OVERLAY_CLOSE};
    [session argbOverlay:&close];
    image = [session valueForKey:@"javaFrame"];
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    XCTAssertEqual(pixel, colors[0]);
    uint32_t clear = 0;
    BD_ARGB_OVERLAY draw = {.plane = 0, .cmd = BD_ARGB_OVERLAY_DRAW,
        .w = 1, .h = 1, .stride = 1, .argb = &clear};
    BD_ARGB_OVERLAY flush = {.plane = 0, .cmd = BD_ARGB_OVERLAY_FLUSH};
    [session argbOverlay:&draw];
    [session argbOverlay:&flush];
    image = [session valueForKey:@"javaFrame"];
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    XCTAssertEqual(pixel, colors[2], @"Clearing a plane must reveal the lower plane");
    close.plane = 2;
    [session argbOverlay:&close];
    XCTAssertNil([session valueForKey:@"javaFrame"]);
    [session argbOverlay:&flush];
    XCTAssertNil([session valueForKey:@"javaFrame"], @"An unchanged clear cannot resurrect old graphics");
    CGContextRelease(context);
    CGColorSpaceRelease(space);
}

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
