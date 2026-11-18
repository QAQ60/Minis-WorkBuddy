//
//  ObjCExceptionCatcher.h
//  MinisApp
//
//  Generic @try/@catch bridge for Swift call sites that invoke
//  Objective-C machinery capable of raising NSExceptions Swift cannot
//  catch (perform(_:), accessibility activation, KVC, NSInvocation…).
//  An uncaught NSException reaches __cxa_throw and the C++ terminate
//  handler aborts the whole process — for best-effort paths (debug
//  automation, diagnostics) that trade is never worth it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try/@catch. Returns YES when the
/// block completed normally, NO when it raised — `reason` (nullable out)
/// then carries "<name>: <reason>" for logging.
BOOL MinisCatchObjCException(void (NS_NOESCAPE ^block)(void), NSString *_Nullable *_Nullable reason);

NS_ASSUME_NONNULL_END

/// Returns YES when CloudKit is usable in this process — i.e. the host app
/// actually carries the iCloud entitlements AND the calls the sync stack makes
/// on the way to a live engine all succeed.
///
/// [T-icloud-entitlement-authority] The result is decided first from the
/// `com.apple.developer.icloud-services` entitlement (via SecTaskCopyValue-
/// ForEntitlement), because a container runtime (LiveContainer et al.) re-signs
/// the app WITHOUT it and the CloudKit calls then raise `CKException`, which
/// Swift cannot catch and which aborts the process. Checking the entitlement
/// directly is authoritative; a behavioural probe over container construction,
/// database access and CKSyncEngine init backs it up when the entitlement value
/// cannot be read.
///
/// Memoized: the entitlement set cannot change within a launch.
BOOL MinisCloudKitAvailable(void);

/// Human-readable cause of the last `MinisCloudKitAvailable()` answer, or nil
/// when CloudKit is available. Safe to call from the settings screen to explain
/// to the user why sync is unavailable (e.g. "installed via a container runtime
/// that stripped the iCloud entitlement").
NSString *_Nullable MinisCloudKitUnavailableReason(void);
