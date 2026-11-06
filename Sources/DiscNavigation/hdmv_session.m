#import "hdmv_session.h"
#if __has_include(<CLibbluray.h>)
#include <CLibbluray.h>
#else
#include "libbluray/bluray.h"
#include "libbluray/keys.h"
#include "libbluray/decoders/overlay.h"
#include "file/filesystem.h"
#endif
#if __has_include(<bdj_runtime.h>)
#include <bdj_runtime.h>
#endif
#include <math.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <mach/mach.h>

@interface HDMVDiscVideo ()
@property(nonatomic) NSInteger playlist;
@property(nonatomic) double duration;
@property(nonatomic) NSInteger chapterCount;
@end
@implementation HDMVDiscVideo
@end

@interface DiscARGBPlane : NSObject
@property(nonatomic) NSMutableData *pixels;
@property(nonatomic) unsigned width, height;
@property(nonatomic) UIImage *image;
@end
@implementation DiscARGBPlane
@end

@interface DiscDrainCompletion : NSObject
@property(nonatomic, copy) void (^completion)(BOOL);
- (BOOL)finish:(BOOL)drained;
@end
@implementation DiscDrainCompletion
- (BOOL)finish:(BOOL)drained {
    void (^completion)(BOOL);
    @synchronized (self) {
        completion = self.completion;
        self.completion = nil;
    }
    if (!completion) return NO;
    completion(drained);
    return YES;
}
@end

static dispatch_semaphore_t javaSessionGate(void) {
    static dispatch_semaphore_t gate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gate = dispatch_semaphore_create(1); });
    return gate;
}

static NSURL *javaCacheRoot(void) {
    static NSURL *cache;
    static int lease = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *parent = [manager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        NSData *marker = [@"Plozz disc cache v1\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        if (!parent || ![manager createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Disc runtime cache directory is unavailable (%@ %ld)", error.domain, (long)error.code);
            return;
        }
        NSArray<NSURL *> *children = [manager contentsOfDirectoryAtURL:parent
            includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey] options:0 error:&error];
        if (!children) {
            NSLog(@"Disc runtime cache inventory failed (%@ %ld)", error.domain, (long)error.code);
            return;
        }
        for (NSURL *child in children) {
            NSString *name = child.lastPathComponent;
            if (![name hasPrefix:@"DiscJava-"] || ![[NSUUID alloc] initWithUUIDString:[name substringFromIndex:9]]) continue;
            NSDictionary *attributes = [child resourceValuesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey] error:nil];
            if (![attributes[NSURLIsDirectoryKey] boolValue] || [attributes[NSURLIsSymbolicLinkKey] boolValue]) continue;
            NSURL *identity = [child URLByAppendingPathComponent:@".plozz-disc-cache"];
            NSDictionary *identityAttributes = [identity resourceValuesForKeys:@[NSURLIsSymbolicLinkKey, NSURLFileSizeKey] error:nil];
            if (!identityAttributes || [identityAttributes[NSURLIsSymbolicLinkKey] boolValue] ||
                [identityAttributes[NSURLFileSizeKey] unsignedLongLongValue] != marker.length ||
                ![[NSData dataWithContentsOfURL:identity] isEqualToData:marker]) continue;
            int previous = open([child URLByAppendingPathComponent:@".lease"].fileSystemRepresentation, O_RDWR | O_NOFOLLOW);
            if (previous < 0) {
                NSLog(@"Disc runtime retained an unverifiable previous cache lease (%d)", errno);
                continue;
            }
            if (flock(previous, LOCK_EX | LOCK_NB) == 0) {
                if (![manager removeItemAtURL:child error:&error]) {
                    NSLog(@"Disc runtime cache cleanup failed (%@ %ld)", error.domain, (long)error.code);
                }
            } else if (errno != EWOULDBLOCK) {
                NSLog(@"Disc runtime previous cache lease check failed (%d)", errno);
            }
            close(previous);
        }
        NSURL *candidate = [parent URLByAppendingPathComponent:[@"DiscJava-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        if (![manager createDirectoryAtURL:candidate withIntermediateDirectories:NO attributes:nil error:&error]) {
            NSLog(@"Disc runtime cache creation failed (%@ %ld)", error.domain, (long)error.code);
            return;
        }
        lease = open([candidate URLByAppendingPathComponent:@".lease"].fileSystemRepresentation,
                     O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0600);
        if (lease < 0 || flock(lease, LOCK_EX | LOCK_NB) != 0) {
            NSLog(@"Disc runtime cache lease failed (%d)", errno);
            if (lease >= 0) close(lease);
            lease = -1;
            return;
        }
        if (![marker writeToURL:[candidate URLByAppendingPathComponent:@".plozz-disc-cache"]
                       options:NSDataWritingAtomic error:&error]) {
            NSLog(@"Disc runtime cache identity failed (%@ %ld)", error.domain, (long)error.code);
            close(lease); lease = -1;
            return;
        }
        // The process-held lease protects quarantined threads as well as active playback.
        cache = candidate;
    });
    return cache;
}

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
    BOOL _timedStill, _vmStill, _perItem;
    NSTimeInterval _stillRemaining, _lastStillTick;
    BOOL _openingRecoveryAttempted, _userSelected, _pgEnabled;
    BOOL _openingMenuPending, _openingLeftFirstPlay, _openingMenuSubmitted, _menuCallBlocked;
    unsigned _audioStream, _subtitleStream;
    NSUInteger _finishBytes;
    BOOL _javaSession, _javaLease, _lastPlaybackPaused, _javaFramePending;
    NSMutableDictionary<NSNumber *, DiscARGBPlane *> *_javaPlanes;
    UIImage *_javaFrame;
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
- (void)argbOverlay:(const BD_ARGB_OVERLAY *)event;
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
static void argbOverlay(void *opaque, const BD_ARGB_OVERLAY *event) {
    [(__bridge HDMVSession *)opaque argbOverlay:event];
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
    uint64_t resourceSize = 0;
    for (NSString *path in files) {
        NSArray *parts = [path componentsSeparatedByString:@"/"];
        BOOL discID = [@[@"CERTIFICATE/ID.BDMV", @"CERTIFICATE/BACKUP/ID.BDMV"] containsObject:path.uppercaseString];
        if ((!discID && ![path.uppercaseString hasPrefix:@"BDMV/"]) || [parts containsObject:@".."] ||
            [parts containsObject:@"."] || [parts containsObject:@""] || files[path].longLongValue < 0 ||
            [identities containsObject:path.uppercaseString]) return nil;
        if (![path.uppercaseString hasPrefix:@"BDMV/STREAM/"]) {
            uint64_t size = files[path].unsignedLongLongValue;
            if (size > 64 * 1024 * 1024 || resourceSize > 128 * 1024 * 1024 - size) return nil;
            resourceSize += size;
        }
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

- (void)listVideosWithCompletion:(void (^)(NSArray<HDMVDiscVideo *> *, NSString *))completion {
    dispatch_async(self.queue, ^{
        NSMutableArray<HDMVDiscVideo *> *videos = [NSMutableArray array];
        NSString *failure = nil;
        NSUInteger playlistFiles = 0;
        uint64_t playlistBytes = 0;
        for (NSString *path in self.files) {
            NSString *upper = path.uppercaseString;
            if ([upper hasPrefix:@"BDMV/PLAYLIST/"] && [upper.pathExtension isEqualToString:@"MPLS"]) {
                playlistFiles++;
                int64_t size = self.files[path].longLongValue;
                if (size < 0 || size > 2 * 1024 * 1024) {
                    failure = @"Disc playlist metadata exceeds the supported limit.";
                    break;
                }
                playlistBytes += (uint64_t)size;
                if (playlistBytes > 16 * 1024 * 1024) {
                    failure = @"Disc playlist metadata exceeds the supported limit.";
                    break;
                }
            }
        }
        if (self.stopped || self->_disc) {
            failure = @"The disc inspection is no longer available.";
        } else if (playlistFiles > 1024) {
            failure = @"This disc lists too many videos.";
        } else if (!failure && [self prepareMetadata]) {
            self->_disc = bd_init();
            if (!self->_disc || !bd_open_files(self->_disc, (__bridge void *)self, openDirectory, openFile)) {
                failure = @"The disc videos could not be read.";
            } else {
                uint32_t count = bd_get_titles(self->_disc, TITLES_RELEVANT, 0);
                if (count > 1024) {
                    failure = @"This disc lists too many videos.";
                } else {
                    NSMutableSet<NSNumber *> *playlists = [NSMutableSet set];
                    for (uint32_t index = 0; index < count && !self.stopped && !self->_failed; index++) {
                        BLURAY_TITLE_INFO *info = bd_get_title_info(self->_disc, index, 0);
                        if (!info) { failure = @"A disc video's information could not be read."; break; }
                        if (info->duration && info->clip_count && ![playlists containsObject:@(info->playlist)]) {
                            HDMVDiscVideo *video = [HDMVDiscVideo new];
                            video.playlist = info->playlist;
                            video.duration = (double)info->duration / 90000.0;
                            video.chapterCount = info->chapter_count;
                            [videos addObject:video];
                            [playlists addObject:@(info->playlist)];
                        }
                        bd_free_title_info(info);
                    }
                    if (self.stopped || self->_failed) failure = @"The disc videos could not be read.";
                    else if (!videos.count && !failure) failure = @"This disc has no readable videos.";
                }
            }
        }
        if (!failure && (self.stopped || self->_failed || !self->_disc)) {
            failure = @"The disc videos could not be read.";
        }
        [videos sortUsingComparator:^NSComparisonResult(HDMVDiscVideo *left, HDMVDiscVideo *right) {
            if (left.duration != right.duration) return left.duration > right.duration ? NSOrderedAscending : NSOrderedDescending;
            return [@(left.playlist) compare:@(right.playlist)];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(failure ? nil : videos, failure); });
    });
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
        NSURL *runtime = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"DiscRuntime"];
#if __has_include(<bdj_runtime.h>)
        BOOL runtimePresent = [NSFileManager.defaultManager fileExistsAtPath:runtime.path];
        NSURL *cache = runtimePresent ? javaCacheRoot() : nil;
        if (runtimePresent &&
            (!cache ||
             !plozz_bdj_configure(runtime.fileSystemRepresentation, cache.fileSystemRepresentation))) {
            [self fail:@"Could not prepare the disc runtime"]; return;
        }
#endif
        self->_disc = bd_init();
        if (self->_disc) {
            bd_set_player_setting_str(self->_disc, BLURAY_PLAYER_JAVA_HOME, runtime.fileSystemRepresentation);
            bd_set_player_setting(self->_disc, BLURAY_PLAYER_SETTING_PERSISTENT_STORAGE, 0);
        }
        if (!self->_disc || !bd_open_files(self->_disc, (__bridge void *)self, openDirectory, openFile)) {
            [self fail:@"Could not open the disc"]; return;
        }
        if (self.stopped) return;
        const BLURAY_DISC_INFO *info = bd_get_disc_info(self->_disc);
        self->_javaSession = info && info->bdj_detected;
        if (self->_javaSession) {
#if __has_include(<bdj_runtime.h>)
            if (plozz_bdj_is_quarantined()) {
                [self fail:@"The previous Java menu did not close. Restart Plozz to open another Java menu"]; return;
            }
#endif
            if (dispatch_semaphore_wait(javaSessionGate(), DISPATCH_TIME_NOW) != 0) {
                [self fail:@"Another disc menu is still closing"]; return;
            }
            self->_javaLease = YES;
            self->_javaPlanes = [NSMutableDictionary dictionary];
            if (!info->bdj_handled) {
                [self fail:@"The Java disc runtime is unavailable"]; return;
            }
            bd_register_argb_overlay_proc(self->_disc, (__bridge void *)self, argbOverlay, NULL);
        }
        if (!info || !info->bluray_detected || !info->top_menu_supported ||
            info->aacs_detected || info->bdplus_detected) {
            [self fail:@"This disc's menu format is not supported"]; return;
        }
        if (!bd_set_player_setting(self->_disc, BLURAY_PLAYER_SETTING_REGION_CODE, self->_region)) {
            [self fail:@"Could not configure the selected player region"]; return;
        }
        bd_register_overlay_proc(self->_disc, (__bridge void *)self, overlay);
        self->_openingMenuPending = YES;
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
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (_javaSession && self.playbackPaused != _lastPlaybackPaused) {
        _lastPlaybackPaused = self.playbackPaused;
        if (_title && bd_set_rate(_disc, _lastPlaybackPaused ? 0 : 90000) < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.noticeChanged) self.noticeChanged(@"The disc restricted that playback control.");
            });
        }
    }
    if (_timedStill && _stillRemaining > 0 && !self.playbackPaused) {
        _stillRemaining = MAX(0, _stillRemaining - (now - _lastStillTick));
        if (_stillRemaining == 0) {
            // A final still returns zero because there is no next clip. The
            // following read delivers EOF and resumes the original HDMV program.
            bd_read_skip_still(_disc);
            _timedStill = NO;
            [self publishStillResuming:NO];
            _finishing = YES;
        }
    }
    _lastStillTick = now;
    BOOL drained = NO;
    BOOL audioChanged = NO, subtitleChanged = NO;
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
        if (!event.event || event.event == BD_EVENT_IDLE) {
            if (event.event == BD_EVENT_IDLE && event.param == 1 && !_vmStill) {
                _vmStill = YES;
                [self publishStillResuming:NO];
            }
            drained = YES; break;
        }
        printf("HDMV event=%u parameter=%u\n", event.event, event.param);
        if (event.event == BD_EVENT_TITLE) {
            if (event.param == BLURAY_TITLE_TOP_MENU) {
                _openingMenuPending = NO;
                [self publishMenuRequestPending:NO];
            } else if (event.param != BLURAY_TITLE_FIRST_PLAY) {
                _openingLeftFirstPlay = YES;
            }
        } else if (event.event == BD_EVENT_UO_MASK_CHANGED) {
            _menuCallBlocked = (event.param & BLURAY_UO_MENU_CALL) != 0;
        }
        if (event.event == BD_EVENT_STILL_TIME) {
            if (event.param > 300) { [self fail:@"Invalid disc still duration"]; return; }
            _timedStill = YES;
            _stillRemaining = event.param;
            _lastStillTick = NSProcessInfo.processInfo.systemUptime;
            _finishing = NO;
            [self publishStillResuming:NO];
        } else if (event.event == BD_EVENT_STILL) {
            _vmStill = event.param != 0;
            [self publishStillResuming:!_vmStill];
        }
        if (event.event == BD_EVENT_AUDIO_STREAM) {
            _audioStream = event.param; audioChanged = YES;
        } else if (event.event == BD_EVENT_PG_TEXTST_STREAM) {
            _subtitleStream = event.param; subtitleChanged = YES;
        } else if (event.event == BD_EVENT_PG_TEXTST) {
            _pgEnabled = event.param != 0; subtitleChanged = YES;
        }
        if (event.event == BD_EVENT_PLAYLIST) {
            _finishing = NO;
            _timedStill = NO; _vmStill = NO;
            [self publishStillResuming:NO];
            if (_title) bd_free_title_info(_title);
            _title = bd_get_playlist_info(_disc, event.param, 0);
            if (!_title || !_title->clip_count || _title->clip_count > 1000 || _title->angle_count > 1) {
                [self fail:@"Unsupported disc playlist"]; return;
            }
            _perItem = NO;
            for (unsigned i = 0; i + 1 < _title->clip_count; i++) {
                if (_title->clips[i].still_mode != BLURAY_STILL_NONE) {
                    _perItem = YES;
                }
            }
            if (_perItem && !self.playItemChanged) {
                [self fail:@"This player cannot present pauses between disc video clips."];
                return;
            }
            _clip = 0;
            _playlist = event.param; _selectionPending = YES; _stopPending = NO;
        } else if (event.event == BD_EVENT_PLAYLIST_STOP) {
            _stopPending = YES; _finishing = NO;
            _timedStill = NO; _vmStill = NO;
            [self publishStillResuming:NO];
        } else if (event.event == BD_EVENT_END_OF_TITLE) {
            _finishing = NO;
        } else if (event.event == BD_EVENT_SEEK && !_synchronizing && _playlist >= 0) {
            _selectionPending = YES;
        } else if (event.event == BD_EVENT_PLAYITEM) {
            if (!_title || event.param >= _title->clip_count) {
                [self fail:@"Invalid disc play item"]; return;
            }
            if (_perItem && !_synchronizing) {
                _finishing = NO; _timedStill = NO; _vmStill = NO;
                [self publishStillResuming:NO];
                _selectionPending = YES;
            }
            _clip = event.param;
            audioChanged = YES; subtitleChanged = YES;
        } else if (event.event == BD_EVENT_MENU) {
            @synchronized (self) {
                if (self->_javaPlanes.count) continue;
            }
            _menuOpen = event.param != 0;
            BOOL visible = _menuOpen;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.menuVisibilityChanged) self.menuVisibilityChanged(visible);
            });
        }
    }
    if (!drained) { [self fail:@"Disc event budget exceeded"]; return; }
    // First play may finish its language/region setup by jumping straight to a
    // feature. Honor the original menu request once authored restrictions allow it.
    // BD-J can unmask Menu Call while it is still changing titles. Wait for
    // that title's playlist rather than racing its asynchronous title loader.
    BOOL openingNavigationReady = _openingLeftFirstPlay ? _selectionPending : _menuOpen;
    if (_openingMenuPending && openingNavigationReady &&
        !_openingMenuSubmitted && !_menuCallBlocked) {
        int result = bd_menu_call(_disc, -1);
        NSLog(@"Disc navigation startup menu request accepted=%d", result > 0);
        if (result > 0) {
            _openingMenuSubmitted = YES;
            _selectionPending = NO;
            _stopPending = YES;
            [self pump];
            return;
        }
        _menuCallBlocked = YES;
    }
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
        if (_perItem) {
            BLURAY_CLIP_INFO *item = &_title->clips[_clip];
            if (item->out_time <= item->in_time) {
                [self fail:@"Invalid disc play-item interval"]; return;
            }
            NSString *path = [NSString stringWithFormat:@"BDMV/STREAM/%s.m2ts", item->clip_id];
            double inTime = item->in_time / 90000.0, outTime = item->out_time / 90000.0;
            double start = item->start_time / 90000.0;
            NSInteger playItem = _clip;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.playItemChanged)
                    self.playItemChanged(playlist, playItem, path, inTime, outTime, start, position, generation);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.selectionChanged) self.selectionChanged(playlist, position, generation);
            });
        }
        audioChanged = YES; subtitleChanged = YES;
    }
    [self publishTracksAudio:audioChanged subtitles:subtitleChanged];
}

- (NSInteger)pidForStream:(unsigned)stream subtitle:(BOOL)subtitle {
    if (!_title || _clip >= _title->clip_count || !stream) return -1;
    BLURAY_CLIP_INFO *clip = &_title->clips[_clip];
    unsigned count = subtitle ? clip->pg_stream_count : clip->audio_stream_count;
    BLURAY_STREAM_INFO *streams = subtitle ? clip->pg_streams : clip->audio_streams;
    if (stream > count || !streams || streams[stream - 1].subpath_id != 0xff) return -1;
    return streams[stream - 1].pid;
}

- (void)publishTracksAudio:(BOOL)audio subtitles:(BOOL)subtitles {
    if ((!audio && !subtitles) || _playlist < 0 || !_title || _failed) return;
    NSInteger audioPID = [self pidForStream:_audioStream subtitle:NO];
    NSInteger subtitlePID = [self pidForStream:_subtitleStream subtitle:YES];
    NSInteger generation = _generation;
    BOOL enabled = _pgEnabled;
    BOOL hasAudio = _audioStream && _audioStream != 0xff;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stopped) return;
        if (audio && hasAudio && self.audioPIDChanged) {
            self.audioPIDChanged(audioPID, generation);
        }
        if (subtitles && self.subtitlePIDChanged) self.subtitlePIDChanged(subtitlePID, enabled, generation);
    });
}

- (void)selectTrackPID:(NSInteger)pid subtitle:(BOOL)subtitle generation:(NSInteger)generation
           completion:(void (^)(BOOL))completion {
    dispatch_async(self.queue, ^{
        BOOL accepted = NO;
        if (!self.stopped && !self->_failed && self->_disc) {
            [self pump];
            if (!self->_failed && generation == self->_generation &&
                self->_title && self->_clip < self->_title->clip_count) {
                BLURAY_CLIP_INFO *clip = &self->_title->clips[self->_clip];
                unsigned count = subtitle ? clip->pg_stream_count : clip->audio_stream_count;
                unsigned stream = subtitle ? self->_subtitleStream : self->_audioStream;
                BOOL enabled = !(subtitle && pid < 0);
                if (enabled) {
                    stream = 0;
                    for (unsigned i = 1; i <= count; i++) {
                        if ([self pidForStream:i subtitle:subtitle] == pid) { stream = i; break; }
                    }
                }
                if (!enabled || stream) {
                    int result = bd_select_stream(self->_disc,
                        subtitle ? BLURAY_PG_TEXTST_STREAM : BLURAY_AUDIO_STREAM, stream, enabled);
                    [self pump];
                    accepted = !self->_failed && result >= 0 && generation == self->_generation &&
                        (subtitle ? self->_pgEnabled == enabled &&
                            (!enabled || [self pidForStream:self->_subtitleStream subtitle:YES] == pid)
                         : [self pidForStream:self->_audioStream subtitle:NO] == pid);
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.stopped) completion(accepted);
        });
    });
}

- (void)publishStillResuming:(BOOL)resume {
    BOOL active = _timedStill || _vmStill;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.stopped && self.stillChanged) self.stillChanged(active, resume && !active);
    });
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
- (void)clickAtX:(uint16_t)x y:(uint16_t)y {
    dispatch_async(self.queue, ^{
        if (self.stopped || self->_failed || !self->_disc) return;
        [self pump];
        if (self->_failed || !self->_menuOpen) return;
        int selected = bd_mouse_select(self->_disc, -1, x, y);
        int activated = 0;
        // BD-J reports successful mouse delivery as zero; HDMV reports a hit as one.
        // HDMV itself rejects mouse activation after a miss (never substitute Enter).
        if (selected >= 0) {
            if (selected > 0 || self->_javaSession) self->_userSelected = YES;
            activated = bd_user_input(self->_disc, -1, BD_VK_MOUSE_ACTIVATE);
        }
        if (selected < 0 || activated < 0) {
            NSLog(@"Disc navigation pointer unavailable: selection=%d activation=%d", selected, activated);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.noticeChanged) self.noticeChanged(@"Use the arrow controls for this menu.");
            });
        }
        [self pump];
    });
}
- (void)menu {
    dispatch_async(self.queue, ^{
        if (self.stopped || self->_failed || !self->_disc) return;
        [self publishMenuRequestPending:YES];
        if (bd_menu_call(self->_disc, -1) <= 0) {
            [self publishMenuRequestPending:self->_openingMenuPending];
            NSLog(@"Disc Menu Lab: top-menu call is unavailable at the current disc location");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.stopped && self.noticeChanged) self.noticeChanged(@"The disc menu is not available yet.");
            });
        } else if (self->_openingMenuPending) {
            self->_openingMenuSubmitted = YES;
        }
        [self pump];
    });
}
- (void)publishMenuRequestPending:(BOOL)pending {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.stopped && self.menuRequestPendingChanged) self.menuRequestPendingChanged(pending);
    });
}
- (void)ended:(NSInteger)generation {
    dispatch_async(self.queue, ^{
        if (self.stopped || self->_failed || generation != self->_generation || !self->_title ||
            self->_finishing) return;
        uint64_t size = bd_get_title_size(self->_disc);
        if (size < 192) { [self fail:@"Invalid completed playlist size"]; return; }
        self->_synchronizing = YES;
        BLURAY_CLIP_INFO *item = &self->_title->clips[self->_clip];
        uint64_t itemEnd = item->start_time + item->out_time - item->in_time;
        int64_t position = self->_perItem
            ? bd_seek_time(self->_disc, itemEnd - 1)
            : bd_seek(self->_disc, size - 192);
        [self pump];
        self->_synchronizing = NO;
        if (position < 0 || (uint64_t)position > size ||
            (!self->_perItem && size - (uint64_t)position > 16 * 1024 * 1024)) {
            [self fail:@"Completed playlist has no bounded final access point"]; return;
        }
        // The bounded tail stops at STILL_TIME or PLAYITEM, not the end of the whole title.
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

- (void)argbOverlay:(const BD_ARGB_OVERLAY *)event {
    // Java drawing threads do not provide Cocoa's per-event autorelease pools.
    @autoreleasepool {
        [self handleARGBOverlay:event];
    }
}

- (void)handleARGBOverlay:(const BD_ARGB_OVERLAY *)event {
    if (!event || event->plane > 2 || self.stopped) return;
    @synchronized (self) {
        if (self.stopped) return;
        NSNumber *key = @(event->plane);
        DiscARGBPlane *plane = _javaPlanes[key];
        if (event->cmd == BD_ARGB_OVERLAY_INIT) {
            if (!event->w || !event->h || event->w > 1920 || event->h > 1080) {
                dispatch_async(self.queue, ^{ [self fail:@"Invalid Java disc graphics dimensions"]; });
                return;
            }
            plane = [DiscARGBPlane new];
            plane.width = event->w; plane.height = event->h;
            plane.pixels = [NSMutableData dataWithLength:(NSUInteger)event->w * event->h * 4];
            _javaPlanes[key] = plane;
            return;
        }
        if (event->cmd == BD_ARGB_OVERLAY_DRAW) {
            if (!plane || !event->argb || event->stride < event->w ||
                (unsigned)event->x + event->w > plane.width || (unsigned)event->y + event->h > plane.height) {
                dispatch_async(self.queue, ^{ [self fail:@"Invalid Java disc graphics region"]; });
                return;
            }
            uint32_t *pixels = plane.pixels.mutableBytes;
            for (unsigned row = 0; row < event->h; row++)
                memcpy(pixels + (event->y + row) * plane.width + event->x,
                       event->argb + row * event->stride, event->w * sizeof(uint32_t));
            return;
        }
        if (event->cmd == BD_ARGB_OVERLAY_CLOSE) {
            [_javaPlanes removeObjectForKey:key];
        } else if (event->cmd == BD_ARGB_OVERLAY_FLUSH && plane) {
            NSData *pixels = [plane.pixels copy];
            const uint32_t *values = pixels.bytes;
            BOOL visible = NO;
            for (NSUInteger index = 0; index < pixels.length / sizeof(uint32_t); index++) {
                if (values[index] >> 24) { visible = YES; break; }
            }
            plane.image = nil;
            if (visible) {
                CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
                CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
                CGImageRef image = CGImageCreate(plane.width, plane.height, 8, 32, plane.width * 4, space,
                    kCGBitmapByteOrder32Little | kCGImageAlphaFirst, provider, NULL, false, kCGRenderingIntentDefault);
                plane.image = image ? [UIImage imageWithCGImage:image] : nil;
                if (image) CGImageRelease(image);
                CGColorSpaceRelease(space); CGDataProviderRelease(provider);
                if (!plane.image) {
                    dispatch_async(self.queue, ^{ [self fail:@"Could not render Java disc graphics"]; });
                    return;
                }
            }
        } else {
            dispatch_async(self.queue, ^{ [self fail:@"Unknown Java disc graphics command"]; });
            return;
        }
        unsigned width = 0, height = 0;
        for (DiscARGBPlane *part in _javaPlanes.allValues) {
            if (part.image) { width = MAX(width, part.width); height = MAX(height, part.height); }
        }
        _javaFrame = nil;
        if (width && height) {
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
                kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            CGColorSpaceRelease(space);
            if (!context) {
                [self failJavaGraphicsAtStage:@"context" width:width height:height];
                return;
            }
            for (NSNumber *number in @[@2, @0, @1]) {
                DiscARGBPlane *part = _javaPlanes[number];
                if (part.image) CGContextDrawImage(context, CGRectMake(0, 0, part.width, part.height), part.image.CGImage);
            }
            CGImageRef image = CGBitmapContextCreateImage(context);
            _javaFrame = image ? [UIImage imageWithCGImage:image] : nil;
            if (image) CGImageRelease(image);
            CGContextRelease(context);
            if (!_javaFrame) {
                [self failJavaGraphicsAtStage:@"snapshot" width:width height:height];
                return;
            }
        }
        if (!_javaFramePending) {
            _javaFramePending = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIImage *image;
                @synchronized (self) {
                    image = self->_javaFrame;
                    self->_javaFramePending = NO;
                }
                if (!self.stopped) {
                    dispatch_async(self.queue, ^{ self->_menuOpen = image != nil; });
                    if (self.imageChanged) self.imageChanged(image);
                    if (self.menuVisibilityChanged) self.menuVisibilityChanged(image != nil);
                }
            });
        }
    }
}

- (void)failJavaGraphicsAtStage:(NSString *)stage width:(unsigned)width height:(unsigned)height {
    task_vm_info_data_t memory = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    BOOL measured = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count) == KERN_SUCCESS;
    NSString *event = [NSString stringWithFormat:
        @"disc GRAPHICS_FAILURE stage=%@ width=%u height=%u planes=%lu footprintBytes=%llu",
        stage, width, height, (unsigned long)_javaPlanes.count,
        measured ? (unsigned long long)memory.phys_footprint : 0];
    dispatch_async(self.queue, ^{
        if (self.stopped || self->_failed) return;
        NSLog(@"%@", event);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.diagnosticEvent) self.diagnosticEvent(event);
        });
        [self fail:@"Could not compose Java disc graphics"];
    });
}

- (void)stop {
    self.stopped = YES;
    [self.http invalidateAndCancel];
    dispatch_async(self.queue, ^{
        if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
        if (self->_disc) {
            bd_close(self->_disc);
#if __has_include(<bdj_runtime.h>)
            if (self->_javaLease && plozz_bdj_is_quarantined()) {
                // libbluray retains a quarantined disc for in-flight JNI calls.
                // Keep its callbacks, graphics and source owner alive as well.
                static HDMVSession *quarantinedSession;
                @synchronized (HDMVSession.class) {
                    if (!quarantinedSession) quarantinedSession = self;
                }
                return;
            }
#endif
            self->_disc = NULL;
        }
        if (self->_javaLease) { dispatch_semaphore_signal(javaSessionGate()); self->_javaLease = NO; }
        @synchronized (self) { [self->_javaPlanes removeAllObjects]; self->_javaFrame = nil; }
        if (self->_title) { bd_free_title_info(self->_title); self->_title = NULL; }
        free(self->_pixels); self->_pixels = NULL;
        free(self->_indices); self->_indices = NULL;
        [self.metadata removeAllObjects];
    });
}

- (void)drainWithCompletion:(void (^)(BOOL))completion {
    DiscDrainCompletion *result = [DiscDrainCompletion new];
    result.completion = completion;
    dispatch_async(self.queue, ^{ [result finish:YES]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if ([result finish:NO]) {
            NSLog(@"Disc navigation shutdown is still pending; native ownership is retained");
        }
    });
}
@end
