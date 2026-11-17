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

BOOL MinisCloudKitAvailable(void) {
    if (_ckChecked) return _ckAvailable;
    _ckChecked = YES;
    NSString *reason = nil;
    // The probe is exactly the call the crash comes from. Holding the
    // container alive for the process is fine: a real app wants the
    // container anyway, and a container runtime pays nothing for it.
    @try {
        _ckAvailable = [CKContainer containerWithIdentifier:@"iCloud.com.openminis.app"] != nil;
    } @catch (NSException *ex) {
        _ckAvailable = NO;
        reason = [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason ?: @""];
    }
    if (!_ckAvailable) {
        NSLog(@"[CloudKit] unavailable in this process (%@) — sync stays disabled", reason ?: @"unknown");
    }
    return _ckAvailable;
}
