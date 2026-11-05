#import <UIKit/UIKit.h>
#include <jni.h>
#include <pthread.h>
#include <TargetConditionals.h>
#include <stdio.h>

static UILabel *statusLabel;
static NSString *statusText = @"Running automated checks...";

#ifdef PLOZZ_BDJ_SMOKE
static UIImageView *menuView;
static UIImage *menuImage;
static UIImage *menuSnapshot;
static BOOL presentationFinished;

static UIImage *menuFrame(const uint32_t *pixels, unsigned width, unsigned height) {
    NSData *bytes = [NSData dataWithBytes:pixels length:(size_t)width * height * 4];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, colors,
        kCGBitmapByteOrder32Little | kCGImageAlphaFirst, provider, NULL, false,
        kCGRenderingIntentDefault);
    UIImage *frame = nil;
    if (image) {
        frame = [UIImage imageWithCGImage:image];
        CGImageRelease(image);
    } else {
        NSLog(@"Failed to create a CGImage for the BD-J overlay");
    }
    CGColorSpaceRelease(colors);
    CGDataProviderRelease(provider);
    return frame;
}

void disc_menu_present(const uint32_t *pixels, unsigned width, unsigned height) {
    @autoreleasepool {
        UIImage *frame = menuFrame(pixels, width, height);
        if (frame) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (presentationFinished) return;
                menuImage = frame;
                menuView.image = frame;
            });
        }
    }
}

void disc_menu_capture(const uint32_t *pixels, unsigned width, unsigned height) {
    @autoreleasepool {
        UIImage *frame = menuFrame(pixels, width, height);
        if (frame) {
            dispatch_async(dispatch_get_main_queue(), ^{
                menuSnapshot = frame;
            });
        }
    }
}
#endif

static void saveResult(NSString *status, NSString *detail) {
    @autoreleasepool {
        NSDictionary *result = @{@"status": status, @"detail": detail,
            @"platform": TARGET_OS_SIMULATOR ? @"tvOS Simulator" : @"tvOS",
            @"physical_device": TARGET_OS_SIMULATOR ? @NO : @YES,
            @"run_id": [NSBundle.mainBundle objectForInfoDictionaryKey:@"PlozzLabRunID"]};
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
        NSString *directory = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [directory stringByAppendingPathComponent:@"runtime-result.json"];
        if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
            NSLog(@"Runtime evidence write failed: %@", error);
        }
        NSLog(@"Runtime smoke %@: %@", status, detail);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL passed = [status isEqualToString:@"pass"];
#ifdef PLOZZ_BDJ_SMOKE
            presentationFinished = YES;
            if (passed && menuSnapshot) {
                menuImage = menuSnapshot;
                menuView.image = menuSnapshot;
                statusText = @"Checks passed - captured menu\nNot interactive. You can leave.";
            } else {
                statusText = [NSString stringWithFormat:@"Checks incomplete: %@\nSee runtime logs.", detail];
            }
#else
            statusText = passed ? @"Java checks passed. You can leave." :
                [NSString stringWithFormat:@"Java checks failed: %@", detail];
#endif
            statusLabel.text = statusText;
        });
    }
}

static void *runJava(void *unused) {
    (void)unused;
    @autoreleasepool {
        NSString *resources = NSBundle.mainBundle.bundlePath;
        NSString *evidence = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (!freopen([[evidence stringByAppendingPathComponent:@"runtime-stdout.log"] fileSystemRepresentation],
                     "w", stdout) ||
            !freopen([[evidence stringByAppendingPathComponent:@"runtime-stderr.log"] fileSystemRepresentation],
                     "w", stderr)) {
            saveResult(@"failed", @"Could not open runtime evidence logs.");
            return NULL;
        }
        setbuf(stdout, NULL);
        setbuf(stderr, NULL);
#ifdef PLOZZ_BDJ_SMOKE
        extern int disc_menu_navigation(int argc, char **argv);
        NSString *directory = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSString *disc = [resources stringByAppendingPathComponent:@"disc"];
        NSString *home = [resources stringByAppendingPathComponent:@"runtime"];
        NSString *jars = [[resources stringByAppendingPathComponent:@"jars"] stringByAppendingString:@"/"];
        NSString *options = [NSString stringWithFormat:
            @"-Xint -Xrs -XX:-UsePerfData -XX:+UseSerialGC "
            "-XX:+UnlockDiagnosticVMOptions -XX:-ImplicitNullChecks "
            "-Djava.security.manager=allow -Djava.io.tmpdir=%@ "
            "-XX:ErrorFile=%@hs_err_pid%%p.log", NSTemporaryDirectory(), NSTemporaryDirectory()];
        setenv("LIBBLURAY_CP", jars.UTF8String, 1);
        setenv("JAVA_TOOL_OPTIONS", options.UTF8String, 1);
        setenv("BD_DEBUG_MASK", "0x00000800", 1);
        char *arguments[] = {"navigation", (char *)disc.UTF8String,
                            (char *)home.UTF8String, (char *)directory.UTF8String};
        int result = disc_menu_navigation(4, arguments);
        saveResult(result == 0 ? @"pass" : @"failed",
                   @"BD-J navigation: ARGB menu, Enter, top menu, Right, Enter, two playlist reads.");
#else
        NSString *classes = [resources stringByAppendingPathComponent:@"classes"];
        NSArray<NSString *> *settings = @[
            @"-Xint", @"-Xrs", @"-Xms16m", @"-Xmx128m", @"-XX:+UseSerialGC",
            @"-XX:-UsePerfData", @"-XX:+UnlockDiagnosticVMOptions", @"-XX:-ImplicitNullChecks",
            @"-Djava.security.manager=allow",
            [@"-Djava.class.path=" stringByAppendingString:classes],
            [@"-Djava.io.tmpdir=" stringByAppendingString:NSTemporaryDirectory()],
            [@"-Duser.home=" stringByAppendingString:NSHomeDirectory()],
            [@"-XX:ErrorFile=" stringByAppendingString:
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"hs_err_pid%p.log"]],
        ];
        JavaVMOption options[settings.count];
        for (NSUInteger i = 0; i < settings.count; i++) {
            options[i].optionString = (char *)settings[i].UTF8String;
            options[i].extraInfo = NULL;
        }
        JavaVMInitArgs args = {
            .version = JNI_VERSION_1_8,
            .nOptions = (jint)settings.count,
            .options = options,
            .ignoreUnrecognized = JNI_FALSE,
        };
        JavaVM *vm = NULL;
        JNIEnv *env = NULL;
        jint status = JNI_CreateJavaVM(&vm, (void **)&env, &args);
        if (status != JNI_OK) {
            saveResult(@"failed", [NSString stringWithFormat:@"JNI_CreateJavaVM returned %d", status]);
            return NULL;
        }
        BOOL passed = NO;
        jclass probe = (*env)->FindClass(env, "RuntimeSmoke");
        if (probe) {
            jmethodID failure = (*env)->GetStaticMethodID(env, probe, "expectedFailure", "()V");
            if (failure) {
                (*env)->CallStaticVoidMethod(env, probe, failure);
                jthrowable exception = (*env)->ExceptionOccurred(env);
                (*env)->ExceptionClear(env);
                jclass expected = (*env)->FindClass(env, "java/lang/IllegalStateException");
                if (exception && expected && (*env)->IsInstanceOf(env, exception, expected)) {
                    jmethodID run = (*env)->GetStaticMethodID(env, probe, "run", "()I");
                    if (run) {
                        jint result = (*env)->CallStaticIntMethod(env, probe, run);
                        passed = !(*env)->ExceptionCheck(env) && result == 5050;
                    }
                }
            }
        }
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
        }
        jint destroyed = (*vm)->DestroyJavaVM(vm);
        if (!passed || destroyed != JNI_OK) {
            saveResult(@"failed", [NSString stringWithFormat:
                @"Java checks passed=%d, DestroyJavaVM=%d; see process log", passed, destroyed]);
        } else {
            saveResult(@"pass", @"Zero executed arithmetic, JNI exceptions, file I/O, SHA-256, "
                "a Java thread, process rejection, network permission denial, and VM teardown.");
        }
#endif
    }
    return NULL;
}

@interface SmokeScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation SmokeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
        options:(UISceneConnectionOptions *)options {
    (void)session;
    (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[UIViewController alloc] init];
#ifdef PLOZZ_BDJ_SMOKE
    menuView = [[UIImageView alloc] initWithFrame:self.window.bounds];
    menuView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    menuView.contentMode = UIViewContentModeScaleAspectFit;
    menuView.image = menuImage;
    [self.window.rootViewController.view addSubview:menuView];
#endif
    statusLabel = [[UILabel alloc] init];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.numberOfLines = 0;
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.textColor = UIColor.whiteColor;
    statusLabel.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.8];
    statusLabel.font = [UIFont systemFontOfSize:24];
    statusLabel.text = statusText;
    UIView *root = self.window.rootViewController.view;
    [root addSubview:statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [statusLabel.leadingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor],
        [statusLabel.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor],
        [statusLabel.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
    [self.window makeKeyAndVisible];
}
@end

@interface SmokeApp : UIResponder <UIApplicationDelegate>
@end

@implementation SmokeApp
- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    pthread_attr_t attributes;
    pthread_t thread;
    int status = pthread_attr_init(&attributes);
    if (status == 0) {
        status = pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
        if (status == 0) status = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        if (status == 0) status = pthread_create(&thread, &attributes, runJava, NULL);
        pthread_attr_destroy(&attributes);
    }
    if (status != 0) {
        saveResult(@"failed", [NSString stringWithFormat:@"Java worker creation failed: %d", status]);
    }
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SmokeApp.class));
    }
}
