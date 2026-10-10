//
//  RuntimeBridge.mm
//  CraftLauncher
//
//  Loads and drives the bundled OpenJDK.
//
//  Why this file exists at all: the JVM is a C library, and the only supported way
//  to start it in-process is to call `JLI_Launch` — the exact function the `java`
//  command-line tool calls. Swift cannot declare a variadic-free C function
//  pointer with this signature ergonomically, and the whole thing has to run on
//  the main thread with a hand-built `argv`. So: a small amount of C++ between
//  Swift and the JVM.
//
//  Every environment variable and argument written here is load-bearing. The
//  comments say what breaks without each one, because the failure modes are
//  silent — a black window, or a VM that starts and immediately exits.
//

#import "RuntimeBridge.h"

#include <dlfcn.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#import <mach-o/dyld.h>

// Entitlement probes.
//
// `SecTask.h` is a **private** header: it does not exist in the public iOS SDK, so
// `#import <Security/SecTask.h>` fails with
//
//     fatal error: 'Security/SecTask.h' file not found
//
// The functions themselves are available and linkable; they are simply not declared
// for third parties. Evidence: the upstream PojavLauncher binary lists
// `_SecTaskCreateFromSelf` and `_SecTaskCopyValueForEntitlement` as weakly-bound
// undefined symbols, so a shipping app already resolves them at runtime. Declaring
// them here achieves the same thing without the private header.
//
// Marked weak so that if a future iOS withdraws them, the probes degrade to "no
// entitlement visible" rather than preventing the app from launching. They are
// advisory: a wrong answer changes a warning, never a decision to launch.
extern "C" {

typedef struct __SecTask *SecTaskRef;

SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator)
    __attribute__((weak_import));

CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task,
                                         CFStringRef entitlement,
                                         CFErrorRef *error)
    __attribute__((weak_import));

}

// The header types are stable across JDK 8 through JDK 25 — verified against both
// `jdk8u/jdk/src/share/bin/java.h` and `jdk17u/src/java.base/share/native/libjli/java.h`,
// which declare byte-identical signatures. No version branching is needed.
typedef int JLI_Launch_t(int argc, char **argv,
                         int jargc, const char **jargv,
                         int appclassc, const char **appclassv,
                         const char *fullversion, const char *dotversion,
                         const char *pname, const char *lname,
                         jboolean javaargs, jboolean cpwildcard,
                         jboolean javaw, jint ergo_class);

extern char **environ;

static NSString *g_lastDynamicLoadError = nil;

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Entitlement probes

/// Reads one entitlement off the current process.
///
/// `SecTaskCopyValueForEntitlement` reports the *effective* entitlements, which is
/// what matters — it reflects what the signer actually produced, not what the
/// source .entitlements file asked for. A key that was stripped during signing
/// reads back as absent.
static BOOL CLHasEntitlement(CFStringRef key) {
    // A weak-imported symbol resolves to NULL when the platform does not provide it,
    // so calling through it unchecked would crash rather than degrade. The comment on
    // the declarations above promises a graceful fallback; this is what makes that
    // true.
    if (SecTaskCreateFromSelf == NULL || SecTaskCopyValueForEntitlement == NULL) {
        return NO;
    }

    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) { return NO; }

    CFTypeRef value = SecTaskCopyValueForEntitlement(task, key, NULL);
    CFRelease(task);

    if (!value) { return NO; }

    BOOL granted = NO;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        // Present but `false` grants nothing.
        granted = CFBooleanGetValue((CFBooleanRef)value);
    } else {
        // Non-boolean entitlements (arrays, strings) are present, so granted.
        granted = YES;
    }

    CFRelease(value);
    return granted;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Log capture

/// Captures the JVM's stdout/stderr and forwards it line by line.
///
/// The JVM writes to file descriptor 1/2 directly rather than through NSLog, so
/// the only way to see Minecraft's output is to redirect those descriptors. A pipe
/// plus a reader thread is used rather than a file because the log panel should
/// update while the game runs.
static int g_savedStdout = -1;
static int g_savedStderr = -1;
static int g_pipeRead = -1;
static int g_pipeWrite = -1;
static dispatch_queue_t g_readerQueue = nil;
static volatile int g_captureRunning = 0;
static void (^g_logBlock)(NSString *) = nil;

static BOOL CLJITStartLogCapture(void (^logBlock)(NSString *line), NSString *mirrorPath) {
    if (g_captureRunning) { return YES; }

    int fds[2];
    if (pipe(fds) != 0) { return NO; }
    g_pipeRead = fds[0];
    g_pipeWrite = fds[1];

    // Save the originals so stopLogCapture can put them back.
    g_savedStdout = dup(STDOUT_FILENO);
    g_savedStderr = dup(STDERR_FILENO);

    // The JVM inherits these descriptors, so dup2 is all that is needed — no
    // cooperation from the Java side, and it works for native crashes too.
    dup2(g_pipeWrite, STDOUT_FILENO);
    dup2(g_pipeWrite, STDERR_FILENO);

    // Fully buffer the C stdio layer so a partial line never interleaves.
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    g_logBlock = [logBlock copy];
    g_captureRunning = 1;

    NSFileHandle *mirror = nil;
    if (mirrorPath.length > 0) {
        [[NSFileManager defaultManager] createFileAtPath:mirrorPath contents:nil attributes:nil];
        mirror = [NSFileHandle fileHandleForWritingAtPath:mirrorPath];
    }

    g_readerQueue = dispatch_queue_create("com.craftlauncher.jvm.log", DISPATCH_QUEUE_SERIAL);

    dispatch_async(g_readerQueue, ^{
        char buffer[8192];
        NSMutableData *pending = [NSMutableData data];

        while (g_captureRunning) {
            ssize_t count = read(g_pipeRead, buffer, sizeof(buffer));
            if (count <= 0) {
                if (count < 0 && errno == EINTR) { continue; }
                break;
            }

            [pending appendBytes:buffer length:(NSUInteger)count];

            // Emit complete lines only; a JVM stack trace arrives in many chunks
            // and splitting mid-line makes the log unreadable.
            const char *bytes = (const char *)pending.bytes;
            NSUInteger length = pending.length;
            NSUInteger lineStart = 0;

            for (NSUInteger i = 0; i < length; i++) {
                if (bytes[i] != '\n') { continue; }

                NSUInteger lineLength = i - lineStart;
                if (lineLength > 0 && bytes[lineStart + lineLength - 1] == '\r') { lineLength--; }

                NSString *line = [[NSString alloc] initWithBytes:(bytes + lineStart)
                                                          length:lineLength
                                                        encoding:NSUTF8StringEncoding];
                // A multi-byte character split across reads yields nil; fall back
                // to a lossy decode so the line still appears.
                if (!line) {
                    line = [[NSString alloc] initWithData:[NSData dataWithBytes:(bytes + lineStart)
                                                                        length:lineLength]
                                                 encoding:NSISOLatin1StringEncoding];
                }
                if (line.length > 0) {
                    if (g_logBlock) { g_logBlock(line); }
                    if (mirror) {
                        NSString *out = [line stringByAppendingString:@"\n"];
                        [mirror writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
                    }
                }
                lineStart = i + 1;
            }

            if (lineStart > 0) {
                [pending replaceBytesInRange:NSMakeRange(0, lineStart) withBytes:NULL length:0];
            }
        }

        // Flush whatever is left when the VM exits without a trailing newline.
        if (pending.length > 0) {
            NSString *line = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
            if (line.length > 0) {
                if (g_logBlock) { g_logBlock(line); }
                if (mirror) {
                    [mirror writeData:[[line stringByAppendingString:@"\n"]
                                       dataUsingEncoding:NSUTF8StringEncoding]];
                }
            }
        }

        [mirror closeFile];
    });

    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Implementation

@implementation RuntimeBridge

+ (CLJITStatus)jitStatus {
    // `kern.jit_enable` is set by the kernel for any process that holds a JIT
    // entitlement, whether it came from TrollStore, a jailbreak, or a debugger.
    // The MIB is built by hand because `CTL_KERN`/`KERN_JIT_ENABLE` are not
    // exposed to the iOS SDK.
    int mib[2] = { CTL_KERN, 43 /* KERN_JIT_ENABLE */ };
    int value = 0;
    size_t size = sizeof(value);

    if (sysctl(mib, 2, &value, &size, NULL, 0) != 0) {
        // Not necessarily a failure: some iOS builds do not expose the knob at
        // all, and it was only added in iOS 14.
        return CLJITStatusUnknown;
    }
    return value != 0 ? CLJITStatusEnabled : CLJITStatusDisabled;
}

+ (NSString *)lastDynamicLoadError {
    return g_lastDynamicLoadError;
}

+ (BOOL)hasGetTaskAllow {
    return CLHasEntitlement(CFSTR("get-task-allow"));
}

+ (BOOL)hasLibraryValidationDisabled {
    // Also true on a jailbroken device, where the kernel skips validation for
    // everything; that is the answer we want either way.
    if (CLHasEntitlement(CFSTR("com.apple.security.cs.disable-library-validation"))) {
        return YES;
    }
    // A debugger attach also disables validation, so a JIT-enabled process can
    // dlopen the runtime even without the entitlement.
    int mib[2] = { CTL_KERN, 43 /* KERN_JIT_ENABLE */ };
    int jit = 0;
    size_t size = sizeof(jit);
    return sysctl(mib, 2, &jit, &size, NULL, 0) == 0 && jit != 0;
}

+ (BOOL)hasExtendedMemoryEntitlement {
    return CLHasEntitlement(CFSTR("com.apple.private.memorystatus"));
}

+ (NSArray<NSString *> *)validateRuntimeDependencies {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];

    NSString *frameworks = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSString *libs = [bundlePath stringByAppendingPathComponent:@"libs"];
    NSString *runtimes = [bundlePath stringByAppendingPathComponent:@"java_runtimes"];

    // Directory-level checks first: a missing directory means the bootstrap script
    // was never run, which is a different problem from a partially copied tree.
    NSMutableArray<NSString *> *missingDirectories = [NSMutableArray array];
    for (NSString *directory in @[frameworks, libs, runtimes]) {
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
            [missingDirectories addObject:directory];
        }
    }
    if (missingDirectories.count > 0) {
        g_lastDynamicLoadError = [NSString stringWithFormat:
            @"App 包内缺少 %lu 个运行时目录（Frameworks / libs / java_runtimes）。"
            @"请运行 Scripts/bootstrap-runtime.sh 后重新构建。",
            (unsigned long)missingDirectories.count];
        return missingDirectories;
    }

    // Libraries that must be loadable *before* the VM starts. These are the ones
    // whose absence produces an opaque crash rather than a readable message.
    NSArray<NSString *> *requiredInFrameworks = @[
        @"libgl4es_114.dylib",  // GL → GLES translation, used by 1.20.1 and older
        @"libMoltenVK.dylib",   // Vulkan → Metal, needed by shader packs
        @"libOSMesa.8.dylib",   // the ANGLE-based backend for 1.20.2+
    ];
    for (NSString *name in requiredInFrameworks) {
        NSString *path = [frameworks stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:path]) {
            [missing addObject:path];
        }
    }

    // The Java-side entry point. Without it the VM starts and immediately reports
    // "Could not find or load main class".
    NSString *launcherJar = [libs stringByAppendingPathComponent:@"launcher.jar"];
    if (![fm fileExistsAtPath:launcherJar]) {
        [missing addObject:launcherJar];
    }

    // Each runtime needs both libraries. Checking only `libjli` would let a
    // half-copied runtime through, and the failure would then surface inside the
    // VM where nothing can explain it.
    for (NSString *tag in @[@"java-8-openjdk", @"java-17-openjdk"]) {
        NSString *home = [runtimes stringByAppendingPathComponent:tag];
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:home isDirectory:&isDirectory] || !isDirectory) {
            // A missing runtime is reported, but it is not fatal for the whole app:
            // only the game versions needing it become unlaunchable.
            [missing addObject:home];
            continue;
        }

        BOOL isJava8 = [tag hasPrefix:@"java-8"];
        NSString *jliRelative = isJava8 ? @"lib/jli/libjli.dylib" : @"lib/libjli.dylib";
        for (NSString *relative in @[jliRelative, @"lib/server/libjvm.dylib"]) {
            NSString *path = [home stringByAppendingPathComponent:relative];
            if (![fm fileExistsAtPath:path]) {
                [missing addObject:path];
            }
        }
    }

    g_lastDynamicLoadError = missing.count > 0
        ? [NSString stringWithFormat:
            @"缺少 %lu 个运行时文件，请重新运行 Scripts/bootstrap-runtime.sh。",
            (unsigned long)missing.count]
        : nil;

    return missing;
}

+ (void)stopLogCapture {
    if (!g_captureRunning) { return; }
    g_captureRunning = 0;

    // Close the write end so the reader sees EOF and drains.
    if (g_pipeWrite >= 0) {
        close(g_pipeWrite);
        g_pipeWrite = -1;
    }

    if (g_savedStdout >= 0) {
        dup2(g_savedStdout, STDOUT_FILENO);
        close(g_savedStdout);
        g_savedStdout = -1;
    }
    if (g_savedStderr >= 0) {
        dup2(g_savedStderr, STDERR_FILENO);
        close(g_savedStderr);
        g_savedStderr = -1;
    }

    // Give the reader queue a moment to flush the tail before the fd goes away.
    if (g_readerQueue) {
        dispatch_sync(g_readerQueue, ^{});
        g_readerQueue = nil;
    }

    if (g_pipeRead >= 0) {
        close(g_pipeRead);
        g_pipeRead = -1;
    }
    g_logBlock = nil;
}

// ─────────────────────────────────────────────────────────────────────────────

+ (int)launchJVMWithArguments:(NSArray<NSString *> *)arguments
                     javaHome:(NSString *)javaHome
                     userHome:(NSString *)userHome
                     renderer:(NSString *)renderer
                        width:(int)width
                        height:(int)height
                  environment:(NSDictionary<NSString *, NSString *> *)environment
                     logBlock:(void (^)(NSString *))logBlock {

    if (arguments.count == 0) {
        if (logBlock) { logBlock(@"错误：JVM 参数为空，已中止启动。"); }
        return -3;
    }

    // ── Environment ──────────────────────────────────────────────────────────
    // Set before the VM starts: JLI_Launch reads the process environment, and
    // several of these are consumed by the Java-side launcher and by LWJGL.
    setenv("POJAV_HOME", userHome.UTF8String, 1);
    setenv("POJAV_GAME_DIR", userHome.UTF8String, 1);

    // Selects the GL backend. Read by the patched LWJGL to pick which libGL to
    // dlopen; getting this wrong surfaces as "no OpenGL context" from the game.
    setenv("POJAV_RENDERER", renderer.UTF8String, 1);

    // Caciocavallo tries to locate an Android-only library through this path;
    // emptying it silences a NullPointerException during AWT init.
    setenv("LD_LIBRARY_PATH", "", 1);

    // GL4ES tuning. Overloaded-function interception is broken for 1.17+ shaders.
    setenv("LIBGL_NOINTOVLHACK", "1", 1);
    // Fixes washed-out banner and sheep colours.
    setenv("LIBGL_NORMALIZE", "1", 1);
    // Zink/ANGLE advertise 4.1; without the override the game may pick a GL 2.1
    // path and render nothing.
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);

    // Lets the VM be started from a thread that is not thread 0. Required here
    // because UIKit owns the main thread.
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);

    // Command-line-visible identity, used by some mods to detect the platform.
    setenv("POJAV_LAUNCHER_NAME", "CraftLauncher", 1);
    setenv("POJAV_LAUNCHER_VERSION", "1.0.0", 1);

    for (NSString *key in environment) {
        setenv(key.UTF8String, environment[key].UTF8String, 1);
    }

    // ── Locate libjli ────────────────────────────────────────────────────────
    // Java 8 nests it under `lib/jli/`; Java 9+ moved it to `lib/`.
    NSString *jliPath8  = [javaHome stringByAppendingPathComponent:@"lib/jli/libjli.dylib"];
    NSString *jliPath11 = [javaHome stringByAppendingPathComponent:@"lib/libjli.dylib"];

    NSString *jliPath = [[NSFileManager defaultManager] fileExistsAtPath:jliPath8]
        ? jliPath8
        : jliPath11;

    if (![[NSFileManager defaultManager] fileExistsAtPath:jliPath]) {
        NSString *message = [NSString stringWithFormat:
            @"找不到 libjli.dylib：%@\nJava 运行时可能没有完整解压，请到「设置 → Java 运行时」重新安装。",
            jliPath];
        if (logBlock) { logBlock(message); }
        g_lastDynamicLoadError = message;
        return -1;
    }

    // RTLD_GLOBAL so libjvm and the patched natives can resolve symbols against
    // each other; without it the VM loads but JNI lookups fail at first use.
    void *libjli = dlopen(jliPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!libjli) {
        const char *error = dlerror();
        NSString *message = [NSString stringWithFormat:
            @"无法加载 libjli.dylib：%s", error ? error : "未知错误"];
        if (logBlock) { logBlock(message); }
        g_lastDynamicLoadError = message;
        return -1;
    }

    JLI_Launch_t *launch = (JLI_Launch_t *)dlsym(libjli, "JLI_Launch");
    if (!launch) {
        NSString *message = @"libjli.dylib 中没有 JLI_Launch 符号，运行时文件可能已损坏。";
        if (logBlock) { logBlock(message); }
        g_lastDynamicLoadError = message;
        return -2;
    }

    // ── Build argv ───────────────────────────────────────────────────────────
    // JLI_Launch keeps pointers into this array for the life of the VM, so nothing
    // here may be freed or moved while it runs. A stable heap block is allocated
    // and intentionally never released.
    NSUInteger count = arguments.count;
    char **argv = (char **)calloc(count + 1, sizeof(char *));
    if (!argv) {
        if (logBlock) { logBlock(@"内存不足，无法构建 JVM 参数。"); }
        return -3;
    }

    NSMutableArray<NSData *> *keepAlive = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSData *utf8 = [arguments[i] dataUsingEncoding:NSUTF8StringEncoding];
        // A parameter that will not encode is a programming error; substituting
        // an empty string keeps argv indices aligned with what the caller expects.
        if (!utf8) { utf8 = [NSData data]; }
        [keepAlive addObject:utf8];
        argv[i] = (char *)utf8.bytes;
    }
    argv[count] = NULL;

    // ── Log capture ──────────────────────────────────────────────────────────
    NSString *consolePath = [userHome stringByAppendingPathComponent:@"logs/console.log"];
    [[NSFileManager defaultManager] createDirectoryAtPath:
        [consolePath stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL capturing = CLJITStartLogCapture(logBlock, consolePath);
    if (!capturing && logBlock) {
        logBlock(@"警告：无法接管 JVM 输出，控制台将看不到游戏日志。");
    }

    // ── Signals ──────────────────────────────────────────────────────────────
    // A crash reporter may have installed handlers that would swallow the JVM's
    // own SIGSEGV/SIGBUS handling, turning a recoverable Java crash into a silent
    // process death. Reset them to the default so the VM's handler wins.
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS,  SIG_DFL);
    signal(SIGILL,  SIG_DFL);
    signal(SIGFPE,  SIG_DFL);

    if (logBlock) {
        logBlock([NSString stringWithFormat:@"正在启动 Java 虚拟机（Java %@，%@x%d）…",
                  [javaHome lastPathComponent], width, height]);
    }

    // ── Go ───────────────────────────────────────────────────────────────────
    // Values copied from the real `java` launcher. `ergo_class = JNI_TRUE` is the
    // ALWAYS_SERVER_CLASS policy, which makes the VM size its heap for a
    // server-class machine — correct for a phone with several GB of RAM, and it
    // is what the JVM argument list we built assumes.
    int result = launch((int)count, argv,
                        0, NULL,        // no built-in java args
                        0, NULL,        // no built-in app classpath
                        "1.8.0-internal", "1.8",   // ignored by Java 9+, required by 8
                        "java", "openjdk",
                        JNI_FALSE,      // not JAVA_ARGS
                        JNI_TRUE,       // honour classpath wildcards — we rely on `libs/*`
                        JNI_FALSE,      // not javaw (Windows-only)
                        JNI_TRUE);      // ALWAYS_SERVER_CLASS ergonomics

    [self stopLogCapture];

    if (logBlock) {
        logBlock([NSString stringWithFormat:@"Java 虚拟机已退出，返回码 %d。", result]);
    }

    return result;
}

@end
