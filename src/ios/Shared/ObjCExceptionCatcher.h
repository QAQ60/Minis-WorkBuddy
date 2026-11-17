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

/// Returns YES when constructing `CKContainer(identifier:)` is safe in this
/// process — i.e. the host app actually carries the iCloud entitlements.
/// A container runtime (LiveContainer et al.) re-signs the app WITHOUT the
/// embedded entitlements, and the first CKContainer init then raises
/// `CKException` ("process must have com.apple.developer.icloud-services
/// entitlement"), which Swift cannot catch and which aborts the process.
/// Memoized: the entitlement set cannot change within a launch.
BOOL MinisCloudKitAvailable(void);
