#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import "DiscMenuPlayer-Swift.h"
#import "hdmv_session.h"
#include "libbluray/keys.h"
#include <TargetConditionals.h>

@interface LiveController : UIViewController <DiscMenuPlayerDelegate>
@property(nonatomic) DiscMenuPlayer *player;
@property(nonatomic) HDMVSession *disc;
@property(nonatomic) UIImageView *overlay;
@property(nonatomic) UILabel *status;
@property(nonatomic) NSMutableArray *selections;
@property(nonatomic) NSMutableArray *samples;
@property(nonatomic) NSMutableArray *frames;
@property(nonatomic) NSMutableArray *phases;
@property(nonatomic) NSInteger generation;
@property(nonatomic) NSInteger automaticStage;
@property(nonatomic) double generationStart;
@property(nonatomic) BOOL automatic;
@property(nonatomic) BOOL automaticStartupInputSent;
@property(nonatomic) BOOL playing;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL failed;
@property(nonatomic) double lastSaved;
@end

@implementation LiveController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.selections = [NSMutableArray array]; self.samples = [NSMutableArray array];
    self.frames = [NSMutableArray array]; self.phases = [NSMutableArray array];
    self.automatic = [NSProcessInfo.processInfo.arguments containsObject:@"--lab-auto"];
    self.generationStart = -1;
    self.status = [UILabel new];
    self.status.textColor = UIColor.whiteColor;
    self.status.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.75];
    self.status.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
    self.status.numberOfLines = 2;
    self.status.text = @"Disc Menu Lab - opening disc\nExperimental movie selection; audio/subtitle menus are not connected.";
    NSURL *configuration = [NSBundle.mainBundle URLForResource:@"disc" withExtension:@"json"];
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                mode:AVAudioSessionModeMoviePlayback options:0 error:&error] ||
        ![[AVAudioSession sharedInstance] setActive:YES error:&error]) {
        self.status.text = @"Audio session could not initialize.";
        [self.view addSubview:self.status]; return;
    }
    self.player = [[DiscMenuPlayer alloc] initWithConfiguration:configuration error:&error];
    if (!self.player) {
        self.status.text = @"Player could not initialize. See the lab log.";
        NSLog(@"Disc Menu Lab: player initialization failed (%@ %ld)", error.domain, (long)error.code);
        [self.view addSubview:self.status]; return;
    }
    self.player.delegate = self;
    [self addChildViewController:self.player];
    [self.view addSubview:self.player.view];
    [self.player didMoveToParentViewController:self];
    self.overlay = [UIImageView new]; self.overlay.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:self.overlay];
    [self.view addSubview:self.status];
    self.disc = [[HDMVSession alloc] initWithConfiguration:configuration error:&error];
    if (!self.disc) {
        self.status.text = @"Disc configuration is invalid."; [self.player shutdown]; return;
    }
    __weak LiveController *weakSelf = self;
    self.disc.imageChanged = ^(UIImage *image) { weakSelf.overlay.image = image; };
    self.disc.noticeChanged = ^(NSString *notice) { weakSelf.status.text = notice; };
    self.disc.statusChanged = ^(NSString *status) {
        LiveController *controller = weakSelf;
        if (!controller || controller.finished) return;
        controller.status.text = status; controller.playing = NO; controller.failed = YES;
        [controller.player stopPlayback];
        [controller.disc stop];
        [controller save:@"navigation-error"];
    };
    self.disc.selectionChanged = ^(NSInteger playlist, double position, NSInteger generation) {
        LiveController *controller = weakSelf;
        if (!controller || controller.finished) return;
        controller.generation = generation; controller.playing = NO; controller.generationStart = -1;
        if (playlist < 0) {
            [controller.player stopPlayback]; controller.status.text = @"Disc stopped.";
            [controller save:@"idle"]; return;
        }
        [controller.selections addObject:@{@"playlist": @(playlist), @"position": @(position),
                                          @"generation": @(generation)}];
        if (controller.selections.count > 32) [controller.selections removeObjectAtIndex:0];
        controller.status.text = @"Loading with AetherEngine...";
        [controller.player loadPlaylist:playlist position:position generation:generation];
        [controller save:@"loading"];
    };
    for (NSNumber *direction in @[@(UISwipeGestureRecognizerDirectionUp), @(UISwipeGestureRecognizerDirectionDown),
                                  @(UISwipeGestureRecognizerDirectionLeft), @(UISwipeGestureRecognizerDirectionRight)]) {
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swiped:)];
        swipe.direction = direction.unsignedIntegerValue;
        [self.view addGestureRecognizer:swipe];
    }
    [self.disc start];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.finished && !self.failed && !self.samples.count) {
            self.status.text = @"Playback has not started. Disc startup is still pending.";
            [self save:@"startup-timeout"];
        }
    });
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.player.view.frame = self.view.bounds; self.overlay.frame = self.view.bounds;
    self.status.frame = CGRectMake(40, 24, MAX(0, self.view.bounds.size.width - 80), 66);
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated]; [self becomeFirstResponder];
}
- (void)swiped:(UISwipeGestureRecognizer *)gesture {
    [self takeManualControl];
    unsigned key = gesture.direction == UISwipeGestureRecognizerDirectionUp ? BD_VK_UP :
        gesture.direction == UISwipeGestureRecognizerDirectionDown ? BD_VK_DOWN :
        gesture.direction == UISwipeGestureRecognizerDirectionLeft ? BD_VK_LEFT : BD_VK_RIGHT;
    [self.disc key:key];
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self takeManualControl];
    NSMutableSet *unhandled = [NSMutableSet set];
    for (UIPress *press in presses) {
        switch (press.type) {
            case UIPressTypeUpArrow: [self.disc key:BD_VK_UP]; break;
            case UIPressTypeDownArrow: [self.disc key:BD_VK_DOWN]; break;
            case UIPressTypeLeftArrow: [self.disc key:BD_VK_LEFT]; break;
            case UIPressTypeRightArrow: [self.disc key:BD_VK_RIGHT]; break;
            case UIPressTypeSelect: [self.disc key:BD_VK_ENTER]; break;
            case UIPressTypeMenu: [self.disc menu]; break;
            case UIPressTypePlayPause: [self.player togglePause]; break;
            default: [unhandled addObject:press]; break;
        }
    }
    if (unhandled.count) [super pressesBegan:unhandled withEvent:event];
}
- (void)takeManualControl {
    if (!self.automatic) return;
    self.automatic = NO; self.automaticStage = -1;
    printf("HDMV automatic probe cancelled by manual input\n");
    [self save:@"manual-control"];
}
- (void)discPlayerPhase:(NSString *)phase generation:(NSInteger)generation {
    if (self.finished || self.failed || generation != self.generation) return;
    self.playing = [phase isEqualToString:@"playing"];
    if ([phase isEqualToString:@"error"] || [phase isEqualToString:@"load-failed"] ||
        [phase isEqualToString:@"invalid-selection"]) self.failed = YES;
    [self.phases addObject:@{@"generation": @(generation), @"phase": phase,
                            @"wall_time": @(NSDate.date.timeIntervalSince1970)}];
    if (self.phases.count > 80) [self.phases removeObjectAtIndex:0];
    if ([phase isEqualToString:@"ended"]) [self.disc ended:generation];
    self.status.text = [NSString stringWithFormat:
        @"Disc Menu Lab - %@ | Back: disc menu | Play/Pause\nExperimental movie selection; audio/subtitle menus are not connected.", phase];
    [self save:phase];
}
- (void)discPlayerTime:(double)seconds generation:(NSInteger)generation {
    if (self.finished || !self.playing || generation != self.generation) return;
    [self.disc updateTime:seconds generation:generation];
    double now = NSDate.date.timeIntervalSince1970;
    if (now - self.lastSaved < 1) return;
    self.lastSaved = now;
    [self.samples addObject:@{@"generation": @(generation), @"position": @(seconds), @"wall_time": @(now)}];
    if (self.samples.count > 120) [self.samples removeObjectAtIndex:0];
    [self save:@"playing"];
    if (self.generationStart < 0) self.generationStart = seconds;
    if (self.automatic && !self.automaticStartupInputSent && !self.overlay.image &&
        seconds - self.generationStart >= 2) {
        self.automaticStartupInputSent = YES;
        [self.disc key:BD_VK_UP];
    }
    if (self.automatic && seconds - self.generationStart >= 6 &&
        (self.automaticStage % 2 == 1 || self.overlay.image)) [self advanceAutomaticProbe];
}
- (void)discPlayerFrame:(double)seconds checksum:(uint64_t)checksum generation:(NSInteger)generation {
    if (self.finished || generation != self.generation) return;
    [self.frames addObject:@{@"generation": @(generation), @"item_time": @(seconds),
                            @"checksum": [NSString stringWithFormat:@"%016llx", (unsigned long long)checksum]}];
    if (self.frames.count > 600) [self.frames removeObjectAtIndex:0];
}
- (void)advanceAutomaticProbe {
    if (self.automaticStage >= 6) {
        self.automatic = NO; self.automaticStage = 7; [self save:@"probe-complete"]; return;
    }
    NSInteger stage = self.automaticStage++;
    self.generationStart = INFINITY;
    if (stage % 2 == 1) { [self.disc menu]; return; }
    [self.disc key:BD_VK_RIGHT]; [self.disc key:BD_VK_ENTER];
    for (NSInteger i = 0; i < stage / 2; i++) [self.disc key:BD_VK_DOWN];
    [self.disc key:BD_VK_ENTER];
}
- (void)save:(NSString *)phase {
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSDictionary *receipt = @{
        @"run_id": [NSBundle.mainBundle objectForInfoDictionaryKey:@"PlozzLabRunID"] ?: @"missing",
        @"platform": TARGET_OS_SIMULATOR ? @"tvOS Simulator" : @"tvOS",
        @"physical_device": TARGET_OS_SIMULATOR ? @NO : @YES,
        @"phase": phase, @"engine": @"AetherEngine", @"selections": self.selections,
        @"clock_samples": self.samples, @"finished": @(self.finished),
        @"video_frames": self.frames, @"phases": self.phases, @"automatic_stage": @(self.automaticStage),
        @"startup_input_probe_sent": @(self.automaticStartupInputSent),
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:&error];
    if (!data || ![data writeToURL:[cache URLByAppendingPathComponent:@"live-result.json"]
                           options:NSDataWritingAtomic error:&error]) {
        NSLog(@"Disc Menu Lab: receipt write failed (%@ %ld)", error.domain, (long)error.code);
    }
}
- (void)shutdown {
    if (self.finished) return;
    self.finished = YES; self.playing = NO;
    [self.player shutdown]; [self.disc stop];
    self.status.text = @"Session stopped. Reopen Disc Menu Lab to start again.";
    [self save:@"stopped"];
}
@end

@interface LiveScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) LiveController *controller;
@end
@implementation LiveScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    freopen([[cache URLByAppendingPathComponent:@"live-stdout.log"].path fileSystemRepresentation], "w", stdout);
    freopen([[cache URLByAppendingPathComponent:@"live-stderr.log"].path fileSystemRepresentation], "w", stderr);
    setbuf(stdout, NULL); setbuf(stderr, NULL);
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.controller = [LiveController new]; self.window.rootViewController = self.controller;
    [self.window makeKeyAndVisible];
}
- (void)sceneDidEnterBackground:(UIScene *)scene { (void)scene; [self.controller shutdown]; }
- (void)sceneWillEnterForeground:(UIScene *)scene {
    (void)scene;
    if (self.controller.finished) {
        self.controller = [LiveController new]; self.window.rootViewController = self.controller;
    }
}
- (void)sceneDidDisconnect:(UIScene *)scene { (void)scene; [self.controller shutdown]; }
@end
@interface LiveApp : UIResponder <UIApplicationDelegate>
@end
@implementation LiveApp
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(LiveApp.class)); }
}
