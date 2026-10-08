//
//  RuntimeBridge.h
//  CraftLauncher
//
//  The Objective-C++ side of the launcher: everything that must touch the C ABI
//  of the bundled OpenJDK. Kept intentionally tiny — three entry points — so that
//  the Swift side owns all the logic and this file only owns the ABI.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How the process is allowed to execute generated code.
typedef NS_ENUM(NSInteger, CLJITStatus) {
    /// JIT is available: TrollStore, a jailbreak, or an attached debugger.
    CLJITStatusEnabled = 0,
    /// The kernel reports JIT as unavailable. Java will start but run unusably
    /// slowly, or fail outright on newer runtimes.
    CLJITStatusDisabled = 1,
    /// The check itself failed. Treated as "try anyway" rather than blocking a
    /// launch on a probe that is known to be unreliable on some iOS builds.
    CLJITStatusUnknown = 2,
};

/// Probes whether this process may JIT.
///
/// A JIT entitlement may be granted *after* this call (AltStore/SideStore attach a
/// debugger on demand), so a `Disabled` result is a warning to show the user, not
/// a hard gate.
+ (CLJITStatus)jitStatus;

/// Human-readable explanation of the last failed dynamic load, or nil.
///
/// Populated by `validateRuntimeDependencies`, and worth surfacing: "library not
/// loaded: libMoltenVK.dylib" tells a user to re-run the bootstrap script, whereas
/// a bare crash tells them nothing.
+ (nullable NSString *)lastDynamicLoadError;

/// `dlopen`s the libs the JVM will need and reports what is missing.
///
/// Returns an array of paths that could not be loaded. An empty array means every
/// dependency resolved. Call this before `launchJVM` so a missing framework is a
/// clear error message rather than a signal inside the VM.
+ (NSArray<NSString *> *)validateRuntimeDependencies;

/// Starts the JVM and blocks until the game exits.
///
/// **Must be called on the main thread.** The JVM is started with
/// `-XstartOnFirstThread`, which makes the process's first thread the one that
/// owns the Darwin run loop; GLFW requires that thread to be the one that created
/// the window, and on iOS the main thread is the only one with a run loop that
/// UIKit will service.
///
/// @param arguments  Full `argv` for the JVM, where element 0 is the path to the
///                   `java` executable. As produced by `JVMArguments.Invocation`.
/// @param javaHome   Root of the JDK. `libjli.dylib` is located relative to it.
/// @param userHome   Value exported as `POJAV_HOME` and passed as `-Duser.home`.
/// @param renderer   The `POJAV_RENDERER` value selecting the GL backend.
/// @param environment Extra variables merged into the process environment.
/// @return The JVM's exit code. Negative values are launch failures raised by this
///         bridge before the VM started: -1 could not load libjli, -2 `JLI_Launch`
///         symbol missing, -3 empty argv.
+ (int)launchJVMWithArguments:(NSArray<NSString *> *)arguments
                     javaHome:(NSString *)javaHome
                     userHome:(NSString *)userHome
                     renderer:(NSString *)renderer
                        width:(int)width
                        height:(int)height
                  environment:(NSDictionary<NSString *, NSString *> *)environment
                     logBlock:(void (^)(NSString *line))logBlock;

/// Stops capturing stdout/stderr. Called after the JVM exits so the launcher's own
/// logging goes back to the normal console.
+ (void)stopLogCapture;

#pragma mark - Entitlement probes

/// Whether the process carries `get-task-allow`.
///
/// This is the make-or-break check for a certificate-signed install. SideStore,
/// AltStore and SideJITServer all grant JIT by *attaching a debugger*, and iOS
/// refuses the attach unless the target was signed with this entitlement.
///
/// Whether it survives signing depends on the certificate type:
///
/// * a **personal / free developer** certificate — its provisioning profile
///   includes `get-task-allow`, so the signer keeps it, and JIT-by-debugger works;
/// * an **enterprise / distribution** certificate — the profile does not include
///   it, so a signer that cannot inject entitlements (全能签 included) has to drop
///   it, and the debugger attach will be refused.
///
/// Surfacing this in-app turns an unexplainable "JIT activation failed" into a
/// one-line diagnosis.
+ (BOOL)hasGetTaskAllow;

/// Whether the process carries `com.apple.security.cs.disable-library-validation`.
///
/// Needed to `dlopen` the Java runtime's own dylibs. A jailbreak or TrollStore
/// grants it implicitly; on a stock device it comes from the signature.
+ (BOOL)hasLibraryValidationDisabled;

/// Whether the process carries `com.apple.private.memorystatus`, which raises the
/// jetsam ceiling and lets the launcher allocate a larger heap.
+ (BOOL)hasExtendedMemoryEntitlement;

NS_ASSUME_NONNULL_END
