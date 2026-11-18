#import "ObjCExceptionCatcher.h"
#import <CloudKit/CloudKit.h>

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

    // [T-icloud-no-entitlement-container] Probe EVERY hop the sync stack takes
    // on the way to a live engine, inside one @try.
    //
    // The previous probe only constructed `CKContainer(identifier:)` and asked
    // whether it was non-nil. Under a container runtime that specific call can
    // succeed while a later one raises CKException — so a user whose toggle was
    // already persisted as `true` (an OVER-INSTALL over old data, unlike a clean
    // install where the flag is false and nothing is reached) passed the probe,
    // reached the real CloudKit access, and was SIGABRT'd at launch. That is
    // exactly the over-install / delete-and-reinstall asymmetry reported.
    //
    // The hop that matters is `privateCloudDatabase`: it resolves the account,
    // which is what the entitlement gates.
    @try {
        CKContainer *container = [CKContainer containerWithIdentifier:@"iCloud.com.openminis.app"];
        if (container == nil) {
            reason = @"CKContainer returned nil";
        } else {
            // Resolving the private database is where an entitlement-less
            // process trips: CloudKit resolves the account at this point. This
            // is one hop FURTHER than the old probe, which is the gap that let an
            // over-install (flag already true) reach the real crash.
            CKDatabase *priv = container.privateCloudDatabase;
            if (priv == nil) {
                reason = @"privateCloudDatabase returned nil";
            }
        }
        _ckAvailable = (reason == nil);
    } @catch (NSException *ex) {
        _ckAvailable = NO;
        reason = [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason ?: @""];
    }

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
