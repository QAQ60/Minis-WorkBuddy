#import "ObjCExceptionCatcher.h"
#import <CloudKit/CloudKit.h>
#import <Security/Security.h>
#import <os/lock.h>

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

/// Does this process actually carry the iCloud entitlement?
///
/// [T-icloud-entitlement-authority] This is the authoritative test, and the one
/// the previous probe was missing. LiveContainer (and any re-signing container
/// runtime) strips the embedded entitlements, so `com.apple.developer
/// .icloud-services` is absent — yet `+[CKContainer containerWithIdentifier:]`
/// may still hand back an object, because the exception is raised later when
/// CloudKit resolves the account. Reading the entitlement answers the question
/// without relying on which call happens to throw first.
///
/// Returns 1 = present, 0 = absent, -1 = could not determine (caller falls back
/// to the behavioural probe below).
static int MinisHasICloudEntitlement(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (task == NULL) return -1;
    CFTypeRef services = SecTaskCopyValueForEntitlement(
        task, CFSTR("com.apple.developer.icloud-services"), NULL);
    CFRelease(task);
    if (services == NULL) return 0;
    BOOL ok = NO;
    if (CFGetTypeID(services) == CFArrayGetTypeID()) {
        ok = CFArrayGetCount((CFArrayRef)services) > 0;
    }
    CFRelease(services);
    return ok ? 1 : 0;
}

BOOL MinisCloudKitAvailable(void) {
    if (_ckChecked) return _ckAvailable;
    _ckChecked = YES;
    NSString *reason = nil;

    int ent = MinisHasICloudEntitlement();
    if (ent == 0) {
        // Definitive: no entitlement, CloudKit would abort the process.
        _ckAvailable = NO;
        reason = @"com.apple.developer.icloud-services entitlement is missing "
                 @"(app was re-signed by a container runtime?)";
        _ckReason = reason;
        NSLog(@"[CloudKit] unavailable in this process (%@) — sync stays disabled", reason);
        return NO;
    }

    // Entitlement present (or undeterminable) — confirm behaviourally by probing
    // every call the sync stack makes on the way to a live engine, not just the
    // container construction that the previous probe stopped at.
    @try {
        CKContainer *container = [CKContainer containerWithIdentifier:@"iCloud.com.openminis.app"];
        if (container == nil) {
            reason = @"CKContainer returned nil";
        } else if (container.privateCloudDatabase == nil) {
            reason = @"privateCloudDatabase returned nil";
        } else if (@available(iOS 17.0, *)) {
            CKSyncEngineConfiguration *cfg =
                [[CKSyncEngineConfiguration alloc] initWithDatabase:container.privateCloudDatabase
                                                   stateSerialization:nil
                                                           delegate:[[NSObject alloc] init]];
            if ([[CKSyncEngine alloc] initWithConfiguration:cfg] == nil) {
                reason = @"CKSyncEngine returned nil";
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
