#import "ObjCExceptionCatcher.h"
// No CloudKit import: this probe must never call a CloudKit API.

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
    BOOL entitled = NO;

    // [T-icloud-no-entitlement-container] PURELY STATIC — no CloudKit call at
    // all. Every earlier version probed by actually calling CloudKit
    // (CKContainer / privateCloudDatabase / ubiquityIdentityToken) at app
    // startup. Under a container runtime those calls either abort outright
    // (@try/@catch cannot stop an abort) or return a false "available", and the
    // probe itself became the launch crash — which is why each fix round made
    // "opens then crashes" worse into "cannot even open".
    //
    // Instead: read the app's own embedded provisioning profile, which the
    // code-signature embeds as a CMS-signed plist whose payload is NOT
    // encrypted — a plain byte search finds the entitlement key. A container
    // runtime re-signs WITHOUT iCloud entitlements, so the key is absent.
    // This is a file read: it cannot raise, cannot touch CloudKit, cannot abort.
    NSString *profile = [[NSBundle mainBundle] pathForResource:@"embedded"
                                                        ofType:@"mobileprovision"];
    if (profile) {
        NSData *data = [NSData dataWithContentsOfFile:profile];
        if (data) {
            NSString *text = [[NSString alloc] initWithData:data
                                                   encoding:NSISOLatin1StringEncoding];
            entitled = [text rangeOfString:@"com.apple.developer.icloud-services"].location
                       != NSNotFound;
        }
        if (!entitled) {
            reason = @"app provisioning profile has no com.apple.developer.icloud-services "
                      @"entitlement (re-signed by a container runtime?)";
        }
    } else {
        // No embedded profile at all (ad-hoc / container re-sign). That is the
        // same situation as LiveContainer — no iCloud entitlement — so treat it
        // as unavailable rather than guessing.
        reason = @"no embedded provisioning profile with iCloud entitlements";
    }

    _ckAvailable = entitled;
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
