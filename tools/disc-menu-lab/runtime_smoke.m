#import <UIKit/UIKit.h>
#include <jni.h>
#include <pthread.h>

static void saveResult(NSString *status, NSString *detail) {
    @autoreleasepool {
        NSDictionary *result = @{@"status": status, @"detail": detail,
                                 @"platform": @"tvOS Simulator", @"physical_device": @NO};
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
        NSString *directory = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [directory stringByAppendingPathComponent:@"runtime-result.json"];
        if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
            NSLog(@"Runtime evidence write failed: %@", error);
        }
        NSLog(@"Runtime smoke %@: %@", status, detail);
    }
}

static void *runJava(void *unused) {
    (void)unused;
    @autoreleasepool {
        NSString *resources = NSBundle.mainBundle.bundlePath;
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
