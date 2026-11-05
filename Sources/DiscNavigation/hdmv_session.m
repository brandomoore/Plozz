#import "hdmv_session.h"
#if __has_include(<CLibbluray.h>)
#include <CLibbluray.h>
#else
#include "libbluray/bluray.h"
#include "libbluray/decoders/overlay.h"
#include "file/filesystem.h"
#endif
#include <math.h>

#if PLOZZ_DISC_MENU_LAB
@interface LabHTTPGuard : NSObject <NSURLSessionTaskDelegate>
@end
@implementation LabHTTPGuard
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)response; (void)request;
    completionHandler(nil);
}
@end
#endif

@interface HDMVSession () {
    BLURAY *_disc;
    BLURAY_TITLE_INFO *_title;
    uint32_t *_pixels;
    uint8_t *_indices;
    uint32_t _palette[256];
    unsigned _width, _height, _clip, _region;
    NSInteger _playlist, _generation;
    BOOL _selectionPending, _stopPending, _failed, _synchronizing, _hasPalette, _finishing, _menuOpen;
    BOOL _openingRecoveryAttempted, _userSelected, _trackNoticeShown;
    NSUInteger _finishBytes;
}
@property(atomic) BOOL stopped;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t timer;
@property(nonatomic) NSURLSession *http;
@property(nonatomic) NSURL *baseURL;
@property(nonatomic) NSString *authorization;
@property(nonatomic) NSDictionary<NSString *, NSNumber *> *files;
@property(nonatomic) NSDictionary<NSString *, NSArray<NSString *> *> *directories;
@property(nonatomic) NSMutableDictionary<NSString *, NSData *> *metadata;
@property(nonatomic, copy) NSData * _Nullable (^sourceRead)(NSString *, int64_t, int64_t);
- (nullable NSString *)canonicalPath:(NSString *)path;
- (void)fail:(NSString *)message;
- (BOOL)prepareMetadata;
- (nullable NSData *)range:(NSString *)path offset:(int64_t)offset length:(int64_t)length;
- (void)pump;
- (void)overlay:(const BD_OVERLAY *)event;
@end

@interface LabFile : NSObject
@property(nonatomic) HDMVSession *owner;
@property(nonatomic) NSString *path;
@property(nonatomic) int64_t position;
@property(nonatomic) int64_t size;
@property(nonatomic) int64_t cacheStart;
@property(nonatomic) NSData *cache;
@end
@implementation LabFile
@end

static void closeFile(BD_FILE_H *file) {
    (void)CFBridgingRelease(file->internal);
    free(file);
}
static int64_t seekFile(BD_FILE_H *file, int64_t offset, int32_t origin) {
    LabFile *state = (__bridge LabFile *)file->internal;
    int64_t base = origin == SEEK_SET ? 0 : origin == SEEK_CUR ? state.position :
                   origin == SEEK_END ? state.size : -1;
    if (base < 0 || offset < -base || offset > state.size - base) return -1;
    state.position = base + offset;
    return state.position;
}
static int64_t tellFile(BD_FILE_H *file) {
    return ((__bridge LabFile *)file->internal).position;
}
static int64_t readFile(BD_FILE_H *file, uint8_t *buffer, int64_t requested) {
    LabFile *state = (__bridge LabFile *)file->internal;
    if (requested < 0 || requested > 8 * 1024 * 1024 || (!buffer && requested)) {
        [state.owner fail:@"Invalid native read size"];
        return -1;
    }
    int64_t length = MIN(requested, state.size - state.position), count = 0;
    while (count < length && !state.owner.stopped) {
        if (!state.cache || state.position < state.cacheStart ||
            state.position >= state.cacheStart + (int64_t)state.cache.length) {
            state.cacheStart = state.position / (512 * 1024) * (512 * 1024);
            state.cache = [state.owner range:state.path offset:state.cacheStart
                                    length:MIN(512 * 1024, state.size - state.cacheStart)];
            if (!state.cache) return -1;
        }
        int64_t within = state.position - state.cacheStart;
        int64_t amount = MIN(length - count, (int64_t)state.cache.length - within);
        memcpy(buffer + count, (const uint8_t *)state.cache.bytes + within, (size_t)amount);
        state.position += amount;
        count += amount;
    }
    return state.owner.stopped ? -1 : count;
}
static BD_FILE_H *openFile(void *opaque, const char *path) {
    HDMVSession *owner = (__bridge HDMVSession *)opaque;
    NSString *name = path ? [NSString stringWithUTF8String:path] : nil;
    name = name ? [owner canonicalPath:name] : nil;
    NSNumber *size = name ? owner.files[name] : nil;
    if (!size || owner.stopped) return NULL;
    LabFile *state = [LabFile new];
    state.owner = owner; state.path = name; state.size = size.longLongValue;
    BD_FILE_H *file = calloc(1, sizeof(*file));
    if (!file) { [owner fail:@"Could not allocate disc reader"]; return NULL; }
    file->internal = (void *)CFBridgingRetain(state);
    file->close = closeFile; file->seek = seekFile; file->tell = tellFile; file->read = readFile;
    return file;
}

@interface LabDirectory : NSObject
@property(nonatomic) NSArray<NSString *> *names;
@property(nonatomic) NSUInteger position;
@end
@implementation LabDirectory
@end
static void closeDirectory(BD_DIR_H *directory) {
    (void)CFBridgingRelease(directory->internal);
    free(directory);
}
static int readDirectory(BD_DIR_H *directory, BD_DIRENT *entry) {
    LabDirectory *state = (__bridge LabDirectory *)directory->internal;
    if (state.position == state.names.count) return 1;
    const char *name = state.names[state.position++].UTF8String;
    if (!name || strlen(name) >= sizeof(entry->d_name)) return -1;
    strlcpy(entry->d_name, name, sizeof(entry->d_name));
    return 0;
}
static BD_DIR_H *openDirectory(void *opaque, const char *path) {
    HDMVSession *owner = (__bridge HDMVSession *)opaque;
    NSString *name = path ? [NSString stringWithUTF8String:path] : nil;
    if (!name) return NULL;
    for (NSString *candidate in owner.directories) {
        if ([candidate caseInsensitiveCompare:name] == NSOrderedSame) { name = candidate; break; }
    }
    NSArray *names = name ? owner.directories[name] : nil;
    if (!names || owner.stopped) return NULL;
    BD_DIR_H *directory = calloc(1, sizeof(*directory));
    if (!directory) { [owner fail:@"Could not allocate disc directory"]; return NULL; }
    LabDirectory *state = [LabDirectory new]; state.names = names;
    directory->internal = (void *)CFBridgingRetain(state);
    directory->close = closeDirectory; directory->read = readDirectory;
    return directory;
}
static void overlay(void *opaque, const BD_OVERLAY *event) {
    [(__bridge HDMVSession *)opaque overlay:event];
}
static unsigned component(double value) {
    return (unsigned)MAX(0, MIN(255, lround(value)));
}

@implementation HDMVSession
- (instancetype)initWithFiles:(NSDictionary<NSString *, NSNumber *> *)files
                       region:(unsigned)region
                    readRange:(NSData * _Nullable (^)(NSString *, int64_t, int64_t))readRange {
    if (!(self = [super init])) return nil;
    if (!files.count || files.count > 4096 || !readRange || (region != 1 && region != 2 && region != 4)) return nil;
    NSMutableDictionary<NSString *, NSMutableSet *> *directories = [NSMutableDictionary dictionary];
    NSMutableSet *identities = [NSMutableSet set];
    for (NSString *path in files) {
        NSArray *parts = [path componentsSeparatedByString:@"/"];
        if (![path.uppercaseString hasPrefix:@"BDMV/"] || [parts containsObject:@".."] ||
            [parts containsObject:@"."] || [parts containsObject:@""] || files[path].longLongValue < 0 ||
            [identities containsObject:path.uppercaseString]) return nil;
        [identities addObject:path.uppercaseString];
        for (NSUInteger i = 0; i < parts.count; i++) {
            NSString *parent = [[parts subarrayWithRange:NSMakeRange(0, i)] componentsJoinedByString:@"/"];
            if (!directories[parent]) directories[parent] = [NSMutableSet set];
            [directories[parent] addObject:parts[i]];
        }
    }
    if (![identities containsObject:@"BDMV/INDEX.BDMV"]) return nil;
    NSMutableDictionary *lists = [NSMutableDictionary dictionary];
    for (NSString *key in directories) lists[key] = [[directories[key] allObjects] sortedArrayUsingSelector:@selector(compare:)];
    _files = [files copy]; _directories = lists; _region = region; _sourceRead = [readRange copy];
    _automaticRegion = YES;
    _metadata = [NSMutableDictionary dictionary];
    _queue = dispatch_queue_create("app.plozz.disc-navigation", DISPATCH_QUEUE_SERIAL);
    _playlist = -1;
    return self;
}

- (NSString *)canonicalPath:(NSString *)path {
    for (NSString *candidate in self.files) {
        if ([candidate caseInsensitiveCompare:path] == NSOrderedSame) return candidate;
    }
    return nil;
}

- (unsigned)selectedRegion { return _region; }

#if PLOZZ_DISC_MENU_LAB
- (instancetype)initWithConfiguration:(NSURL *)configuration error:(NSError **)error {
    if (!(self = [super init])) return nil;
    NSData *data = [NSData dataWithContentsOfURL:configuration options:0 error:error];
    if (!data) return nil;
    NSDictionary *config = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![config isKindOfClass:NSDictionary.class] || ![config[@"files"] isKindOfClass:NSArray.class] ||
        ![config[@"baseURL"] isKindOfClass:NSString.class] ||
        ![config[@"authorization"] isKindOfClass:NSString.class] ||
        ![@[@1, @2, @4] containsObject:config[@"regionCode"]]) {
        if (error) *error = [NSError errorWithDomain:@"DiscMenuLab" code:1 userInfo:nil];
        return nil;
    }
    _baseURL = [NSURL URLWithString:config[@"baseURL"]];
    _authorization = config[@"authorization"];
    _region = [config[@"regionCode"] unsignedIntValue];
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableSet *> *directories = [NSMutableDictionary dictionary];
    for (NSDictionary *file in config[@"files"]) {
        if (![file isKindOfClass:NSDictionary.class] || ![file[@"path"] isKindOfClass:NSString.class] ||
            ![file[@"size"] isKindOfClass:NSNumber.class]) {
            if (error) *error = [NSError errorWithDomain:@"DiscMenuLab" code:2 userInfo:nil];
            return nil;
        }
        NSString *path = file[@"path"];
        NSArray *parts = [path componentsSeparatedByString:@"/"];
        if (![path hasPrefix:@"BDMV/"] || [parts containsObject:@".."] || [parts containsObject:@"."] ||
            [parts containsObject:@""] || [path containsString:@"/JAR/"] ||
            [path containsString:@"/BDJO/"] || files[path] || [file[@"size"] longLongValue] < 0) {
            if (error) *error = [NSError errorWithDomain:@"DiscMenuLab" code:3 userInfo:nil];
            return nil;
        }
        files[path] = file[@"size"];
        for (NSUInteger i = 0; i < parts.count; i++) {
            NSString *parent = [[parts subarrayWithRange:NSMakeRange(0, i)] componentsJoinedByString:@"/"];
            if (!directories[parent]) directories[parent] = [NSMutableSet set];
            [directories[parent] addObject:parts[i]];
        }
    }
    if (![_baseURL.scheme isEqualToString:@"http"] || !_baseURL.host.length ||
        !_authorization.length || !files.count || files.count > 4096 || !files[@"BDMV/index.bdmv"]) {
        if (error) *error = [NSError errorWithDomain:@"DiscMenuLab" code:4 userInfo:nil];
        return nil;
    }
    NSMutableDictionary *lists = [NSMutableDictionary dictionary];
    for (NSString *key in directories) lists[key] = [[directories[key] allObjects] sortedArrayUsingSelector:@selector(compare:)];
    _files = files; _directories = lists;
    _metadata = [NSMutableDictionary dictionary];
    NSURLSessionConfiguration *http = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    http.timeoutIntervalForRequest = 18; http.timeoutIntervalForResource = 22;
    http.URLCache = nil; http.HTTPCookieStorage = nil; http.URLCredentialStorage = nil;
    _http = [NSURLSession sessionWithConfiguration:http delegate:[LabHTTPGuard new] delegateQueue:nil];
    _queue = dispatch_queue_create("app.plozz.lab.hdmv", DISPATCH_QUEUE_SERIAL);
    _playlist = -1;
    return self;
}
#endif

- (void)fail:(NSString *)message {
    if (_failed || self.stopped) return;
    _failed = YES;
    NSLog(@"Disc Menu Lab: %@", message);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.stopped && self.statusChanged) self.statusChanged(message);
    });
}

- (NSData *)range:(NSString *)path offset:(int64_t)offset length:(int64_t)length {
    if (self.stopped) return nil;
    int64_t size = self.files[path].longLongValue;
    if (!self.files[path] || offset < 0 || offset > size || length <= 0 ||
        length > 512 * 1024 || length > size - offset) {
        [self fail:@"Invalid disc range"]; return nil;
    }
    NSData *cached = self.metadata[path];
    if (cached) return [cached subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)length)];
    if (self.sourceRead) {
        NSData *data = self.sourceRead(path, offset, length);
        if (self.stopped) return nil;
        if (data.length != (NSUInteger)length) { [self fail:@"Could not read the disc file"]; return nil; }
        return data;
    }
#if PLOZZ_DISC_MENU_LAB
    NSString *expected = [NSString stringWithFormat:@"bytes %lld-%lld/%lld",
                          offset, offset + length - 1, size];
    for (unsigned attempt = 0; attempt < 2; attempt++) {
        if (self.stopped) return nil;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self.baseURL URLByAppendingPathComponent:path]];
        [request setValue:self.authorization forHTTPHeaderField:@"Authorization"];
        [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", offset, offset + length - 1]
      forHTTPHeaderField:@"Range"];
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        __block NSData *data = nil;
        __block NSHTTPURLResponse *response = nil;
        __block NSError *failure = nil;
        NSURLSessionDataTask *task = [self.http dataTaskWithRequest:request completionHandler:
            ^(NSData *body, NSURLResponse *result, NSError *error) {
                data = body; response = (NSHTTPURLResponse *)result; failure = error;
                dispatch_semaphore_signal(ready);
            }];
        [task resume];
        BOOL timedOut = dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 24 * NSEC_PER_SEC)) != 0;
        if (timedOut) [task cancel];
        if (self.stopped) return nil;
        NSInteger status = timedOut ? 0 : response.statusCode;
        NSInteger code = timedOut ? NSURLErrorTimedOut : failure.code;
        if (!timedOut && !failure && status == 206 && data.length == (NSUInteger)length &&
            [[response valueForHTTPHeaderField:@"Content-Range"] isEqualToString:expected]) return data;
        BOOL transient = timedOut ||
            ([failure.domain isEqualToString:NSURLErrorDomain] &&
             (code == NSURLErrorTimedOut || code == NSURLErrorNetworkConnectionLost ||
              code == NSURLErrorCannotConnectToHost)) || status == 503 || status == 504;
        if (attempt == 0 && transient) {
            NSLog(@"Disc Menu Lab: retrying range after transient failure (HTTP %ld, error %ld)",
                  (long)status, (long)code);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.noticeChanged) self.noticeChanged(@"Retrying disc read...");
            });
            [NSThread sleepForTimeInterval:0.25];
            continue;
        }
        [self fail:[NSString stringWithFormat:@"Disc range read failed (HTTP %ld, error %ld)",
                    (long)status, (long)code]];
        return nil;
    }
    [self fail:@"Disc range retry budget exhausted"]; return nil;
#else
    [self fail:@"Disc reader is unavailable"]; return nil;
#endif
}

- (BOOL)prepareMetadata {
    uint64_t total = 0;
    for (NSString *path in [[self.files allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *upper = path.uppercaseString;
        if (![upper isEqualToString:@"BDMV/INDEX.BDMV"] &&
            ![upper isEqualToString:@"BDMV/MOVIEOBJECT.BDMV"]) continue;
        int64_t size = self.files[path].longLongValue;
        total += (uint64_t)size;
        if (size > 2 * 1024 * 1024 || total > 16 * 1024 * 1024) {
            [self fail:@"Disc navigation metadata exceeds the supported limit"]; return NO;
        }
        NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)size];
        while (data.length < (NSUInteger)size) {
            NSData *part = [self range:path offset:(int64_t)data.length
                               length:MIN(512 * 1024, size - (int64_t)data.length)];
            if (!part) return NO;
            [data appendData:part];
        }
        self.metadata[path] = [data copy];
    }
    printf("HDMV navigation metadata cached: %llu bytes\n", (unsigned long long)total);
    return !self.stopped;
}

- (void)start {
    dispatch_async(self.queue, ^{
        if (self.stopped || self->_disc) return;
        if (![self prepareMetadata]) return;
        if (self.automaticRegion) {
            NSString *index = [self canonicalPath:@"BDMV/index.bdmv"];
            NSString *objects = [self canonicalPath:@"BDMV/MovieObject.bdmv"];
            if (index && objects && self.metadata[index] && self.metadata[objects]) {
                unsigned region = HDMVPreferredRegion(self.metadata[index], self.metadata[objects]);
                if (region) self->_region = region;
            }
        }
        self->_disc = bd_init();
        if (!self->_disc || !bd_open_files(self->_disc, (__bridge void *)self, openDirectory, openFile)) {
            [self fail:@"Could not open the disc"]; return;
        }
        const BLURAY_DISC_INFO *info = bd_get_disc_info(self->_disc);
        if (!info || !info->bluray_detected || !info->top_menu_supported ||
            info->aacs_detected || info->bdplus_detected) {
            [self fail:@"This disc's menu format is not supported"]; return;
        }
        if (!bd_set_player_setting(self->_disc, BLURAY_PLAYER_SETTING_REGION_CODE, self->_region)) {
            [self fail:@"Could not configure the selected player region"]; return;
        }
        bd_register_overlay_proc(self->_disc, (__bridge void *)self, overlay);
        if (bd_play(self->_disc) <= 0 && bd_menu_call(self->_disc, -1) <= 0) {
            [self fail:@"Disc startup failed"]; return;
        }
        self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
        __weak HDMVSession *weakSelf = self;
        dispatch_source_set_event_handler(self.timer, ^{ [weakSelf pump]; });
        dispatch_resume(self.timer);
    });
}

- (void)pump {
    if (self.stopped || _failed || !_disc) return;
    BOOL drained = NO;
    uint8_t tail[65536];
    for (unsigned i = 0; i < 128; i++) {
        BD_EVENT event = {0};
        int bytes = bd_read_ext(_disc, _finishing ? tail : NULL, _finishing ? sizeof(tail) : 0, &event);
        if (bytes < 0 ||
            event.event == BD_EVENT_ERROR || event.event == BD_EVENT_READ_ERROR ||
            event.event == BD_EVENT_ENCRYPTED) {
            [self fail:@"Native disc navigation failed"]; return;
        }
        if (_finishing) {
            _finishBytes += (NSUInteger)bytes;
            if (_finishBytes > 16 * 1024 * 1024) {
                [self fail:@"Disc end-of-playlist read budget exceeded"]; return;
            }
        }
        if (!event.event) { drained = YES; break; }
        printf("HDMV event=%u parameter=%u\n", event.event, event.param);
        if (event.event == BD_EVENT_STILL_TIME || (event.event == BD_EVENT_STILL && event.param)) {
            [self fail:@"This disc requires still-frame navigation that is not supported yet."];
            return;
        }
        if (_userSelected && !_trackNoticeShown &&
            (event.event == BD_EVENT_AUDIO_STREAM || event.event == BD_EVENT_PG_TEXTST_STREAM ||
             event.event == BD_EVENT_PG_TEXTST)) {
            _trackNoticeShown = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.noticeChanged) {
                    self.noticeChanged(@"Disc track selections aren't supported. Use playback controls.");
                }
            });
        }
        if (event.event == BD_EVENT_PLAYLIST) {
            _finishing = NO;
            if (_title) bd_free_title_info(_title);
            _title = bd_get_playlist_info(_disc, event.param, 0);
            if (!_title || !_title->clip_count || _title->clip_count > 1000 || _title->angle_count > 1) {
                [self fail:@"Unsupported disc playlist"]; return;
            }
            _playlist = event.param; _selectionPending = YES; _stopPending = NO;
        } else if (event.event == BD_EVENT_PLAYLIST_STOP) {
            _stopPending = YES; _finishing = NO;
        } else if (event.event == BD_EVENT_END_OF_TITLE) {
            _finishing = NO;
        } else if (event.event == BD_EVENT_SEEK && !_synchronizing && _playlist >= 0) {
            _selectionPending = YES;
        } else if (event.event == BD_EVENT_PLAYITEM) {
            _clip = event.param;
        } else if (event.event == BD_EVENT_MENU) {
            _menuOpen = event.param != 0;
            BOOL visible = _menuOpen;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.menuVisibilityChanged) self.menuVisibilityChanged(visible);
            });
        }
    }
    if (!drained) { [self fail:@"Disc event budget exceeded"]; return; }
    if (_stopPending && !_selectionPending) {
        _stopPending = NO; _playlist = -1;
        NSInteger generation = ++_generation;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.stopped && self.selectionChanged) self.selectionChanged(-1, 0, generation);
        });
    }
    if (_selectionPending && _playlist >= 0 && !_failed) {
        _selectionPending = NO;
        for (unsigned i = 0; i < _title->clip_count; i++) {
            NSString *clip = [NSString stringWithFormat:@"BDMV/STREAM/%s.m2ts", _title->clips[i].clip_id];
            if (![self canonicalPath:clip]) {
                if (!_openingRecoveryAttempted && !_userSelected) {
                    _openingRecoveryAttempted = YES;
                    if (bd_menu_call(_disc, -1) > 0) { [self pump]; return; }
                }
                [self fail:@"A video file required by the disc is missing"]; return;
            }
        }
        NSInteger playlist = _playlist, generation = ++_generation;
        double position = bd_tell_time(_disc) / 90000.0;
        printf("HDMV selection=%ld position=%.3f generation=%ld\n", (long)playlist, position, (long)generation);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.stopped && self.selectionChanged) self.selectionChanged(playlist, position, generation);
        });
    }
}

- (void)key:(unsigned)key {
    dispatch_async(self.queue, ^{
        if (self.stopped || self->_failed || !self->_disc) return;
        [self pump];
        if (self->_failed) return;
        if (!self->_menuOpen) {
            printf("HDMV input=%u ignored=no-active-menu\n", key);
            return;
        }
        printf("HDMV input=%u\n", key);
        if (key == 16) self->_userSelected = YES;
        if (bd_user_input(self->_disc, -1, key) < 0) {
            NSLog(@"Disc Menu Lab: input %u is unavailable at the current menu location", key);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.noticeChanged) self.noticeChanged(@"That control is unavailable here.");
            });
        }
        [self pump];
    });
}
- (void)menu {
    dispatch_async(self.queue, ^{
        if (self.stopped || self->_failed || !self->_disc) return;
        if (bd_menu_call(self->_disc, -1) <= 0) {
            NSLog(@"Disc Menu Lab: top-menu call is unavailable at the current disc location");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.noticeChanged) self.noticeChanged(@"The disc menu is not available yet.");
            });
        }
        [self pump];
    });
}
- (void)ended:(NSInteger)generation {
    dispatch_async(self.queue, ^{
        if (self.stopped || self->_failed || generation != self->_generation || !self->_title ||
            self->_finishing) return;
        uint64_t size = bd_get_title_size(self->_disc);
        if (size < 192) { [self fail:@"Invalid completed playlist size"]; return; }
        self->_synchronizing = YES;
        int64_t position = bd_seek(self->_disc, size - 192);
        [self pump];
        self->_synchronizing = NO;
        if (position < 0 || (uint64_t)position > size || size - (uint64_t)position > 16 * 1024 * 1024) {
            [self fail:@"Completed playlist has no bounded final access point"]; return;
        }
        // Consume only the final access unit so libbluray resumes the original HDMV program.
        self->_finishBytes = 0; self->_finishing = YES;
        [self pump];
    });
}
- (void)updateTime:(double)seconds generation:(NSInteger)generation {
    if (!isfinite(seconds) || seconds < 0) return;
    dispatch_async(self.queue, ^{
        if (self.stopped || self->_failed || generation != self->_generation || !self->_title) return;
        uint64_t time = (uint64_t)(seconds * 90000);
        unsigned clip = 0;
        while (clip + 1 < self->_title->clip_count && self->_title->clips[clip + 1].start_time <= time) clip++;
        if (clip != self->_clip) {
            self->_synchronizing = YES;
            if (bd_seek_time(self->_disc, time) < 0) [self fail:@"Disc timeline synchronization failed"];
            [self pump];
            self->_synchronizing = NO;
        }
        BLURAY_CLIP_INFO *item = &self->_title->clips[clip];
        bd_set_scr(self->_disc, (int64_t)(time - item->start_time + item->in_time));
    });
}

- (void)overlay:(const BD_OVERLAY *)event {
    if (self.stopped || _failed || !event || event->plane != BD_OVERLAY_IG) return;
    if (event->cmd == BD_OVERLAY_INIT) {
        free(_pixels); free(_indices); _pixels = NULL; _indices = NULL;
        if (!event->w || !event->h || event->w > 1920 || event->h > 1080) {
            [self fail:@"Invalid disc graphics dimensions"]; return;
        }
        _width = event->w; _height = event->h; _hasPalette = NO;
        _pixels = calloc((size_t)_width * _height, sizeof(uint32_t));
        _indices = malloc((size_t)_width * _height);
        if (!_pixels || !_indices) { [self fail:@"Could not allocate disc graphics"]; return; }
        memset(_indices, 255, (size_t)_width * _height);
        return;
    }
    if (!_pixels || !_indices) {
        if (event->cmd != BD_OVERLAY_CLOSE) [self fail:@"Disc graphics used before initialization"];
        return;
    }
    if (event->cmd == BD_OVERLAY_CLEAR || event->cmd == BD_OVERLAY_CLOSE || event->cmd == BD_OVERLAY_HIDE) {
        if (event->cmd != BD_OVERLAY_HIDE) {
            memset(_pixels, 0, (size_t)_width * _height * sizeof(uint32_t));
            memset(_indices, 255, (size_t)_width * _height);
        }
        if (event->cmd != BD_OVERLAY_CLEAR) dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.stopped && self.imageChanged) self.imageChanged(nil);
        });
        return;
    }
    if (event->cmd == BD_OVERLAY_DRAW || event->cmd == BD_OVERLAY_WIPE) {
        if (!event->w || !event->h || (unsigned)event->x + event->w > _width ||
            (unsigned)event->y + event->h > _height) {
            [self fail:@"Invalid disc graphics region"]; return;
        }
        if (event->palette) {
            _hasPalette = YES;
            for (unsigned i = 0; i < 256; i++) {
                BD_PG_PALETTE_ENTRY entry = event->palette[i];
                double y = (entry.Y - 16) * 255.0 / 219.0, cr = entry.Cr - 128, cb = entry.Cb - 128;
                unsigned alpha = i == 255 ? 0 : entry.T;
                _palette[i] = alpha << 24 | component(y + 1.792741 * cr) << 16 |
                              component(y - 0.213249 * cb - 0.532909 * cr) << 8 |
                              component(y + 2.112402 * cb);
            }
        }
        if (event->cmd == BD_OVERLAY_DRAW && !_hasPalette) {
            [self fail:@"Missing disc graphics palette"]; return;
        }
        if (event->cmd == BD_OVERLAY_DRAW && !event->img && !event->palette_update_flag) {
            [self fail:@"Missing disc graphics bitmap"]; return;
        }
        const BD_PG_RLE_ELEM *run = event->img;
        for (unsigned y = 0; y < event->h; y++) {
            uint8_t *row = _indices + (event->y + y) * _width + event->x;
            if (event->cmd == BD_OVERLAY_WIPE) memset(row, 255, event->w);
            else if (run) {
                unsigned x = 0;
                while (x < event->w) {
                    if (!run->len || run->len > event->w - x || run->color > 255) {
                        [self fail:@"Invalid disc graphics run"]; return;
                    }
                    memset(row + x, run->color, run->len); x += run->len; run++;
                }
                if (run->len != 0) { [self fail:@"Invalid disc graphics row"]; return; }
                run++;
            }
            for (unsigned x = 0; x < event->w; x++) {
                _pixels[(event->y + y) * _width + event->x + x] = row[x] == 255 ? 0 : _palette[row[x]];
            }
        }
        return;
    }
    if (event->cmd != BD_OVERLAY_FLUSH) { [self fail:@"Unknown disc graphics command"]; return; }
    NSData *data = [NSData dataWithBytes:_pixels length:(size_t)_width * _height * 4];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(_width, _height, 8, 32, _width * 4, space,
                                    kCGBitmapByteOrder32Little | kCGImageAlphaFirst, provider,
                                    NULL, false, kCGRenderingIntentDefault);
    UIImage *result = image ? [UIImage imageWithCGImage:image] : nil;
    if (image) CGImageRelease(image);
    CGColorSpaceRelease(space); CGDataProviderRelease(provider);
    if (!result) { [self fail:@"Could not render disc graphics"]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.stopped && self.imageChanged) self.imageChanged(result);
    });
}

- (void)stop {
    self.stopped = YES;
    [self.http invalidateAndCancel];
    dispatch_async(self.queue, ^{
        if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
        if (self->_disc) { bd_close(self->_disc); self->_disc = NULL; }
        if (self->_title) { bd_free_title_info(self->_title); self->_title = NULL; }
        free(self->_pixels); self->_pixels = NULL;
        free(self->_indices); self->_indices = NULL;
        [self.metadata removeAllObjects];
    });
}

- (void)drainWithCompletion:(void (^)(void))completion {
    dispatch_async(self.queue, completion);
}
@end
