#import "ObjCExceptionCatcher.h"
#import <CloudKit/CloudKit.h> // still linked; probe no longer constructs CK objects

BOOL MinisCatchObjCException(void (NS_NOESCAPE ^block)(void), NSString *_Nullable *_Nullable reason) {
    @try {
        block();
        return YES;
    } @catch (NSException *ex) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason ?: @"(no reason)"];
        }
        return NO;
    }
}

static BOOL _ckAvailable = NO;
static BOOL _ckChecked = NO;
static NSString *_ckReason = nil;

BOOL MinisCloudKitAvailable(void) {
    if (_ckChecked) return _ckAvailable;
    _ckChecked = YES;
    NSString *reason = nil;

    // [T-icloud-no-entitlement-container] Do NOT try to construct CKContainer
    // or touch privateCloudDatabase here. In a container runtime those calls
    // can return non-nil (a false "available") yet abort later when the real
    // engine resolves the account — and an NSException raised at that depth is
    // not reliably catchable. Worse, running this probe at app init meant the
    // wrong answer here decided whether persisted flags were cleared.
    //
    // `ubiquityIdentityToken` is Apple's own "is iCloud usable here?" query:
    // it is a synchronous, non-throwing read of the ubiquity identity, and it
    // returns nil when the process lacks the iCloud entitlement (or iCloud is
    // not configured). It never touches a CKDatabase, so it cannot abort. No
    // token ⇒ sync cannot work ⇒ treat CloudKit as unavailable.
    id token = nil;
    @try {
        token = [[NSFileManager defaultManager] ubiquityIdentityToken];
    } @catch (NSException *ex) {
        reason = [NSString stringWithFormat:@"ubiquityIdentityToken raised %@: %@",
                  ex.name, ex.reason ?: @""];
    }
    if (token == nil && reason == nil) {
        reason = @"no iCloud ubiquity identity (missing entitlement or not signed in)";
    }
    _ckAvailable = (token != nil && reason == nil);

    _ckReason = reason;
    if (!_ckAvailable) {
        NSLog(@"[CloudKit] unavailable in this process (%@) — sync stays disabled", reason ?: @"unknown");
    }
    return _ckAvailable;
}

NSString *_Nullable MinisCloudKitUnavailableReason(void) {
    // Populate the answer if nobody asked yet, so the settings screen can show
    // the cause without depending on a start() having run first.
    (void)MinisCloudKitAvailable();
    return _ckReason;
}
