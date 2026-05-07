#import "ObjCExceptionCatcher.h"

BOOL AWPerformObjCExceptionSafe(void (NS_NOESCAPE ^work)(void),
                                NSString * _Nullable * _Nullable exceptionName,
                                NSString * _Nullable * _Nullable exceptionReason) {
    @try {
        work();
        return YES;
    } @catch (NSException *exception) {
        if (exceptionName != NULL) {
            *exceptionName = exception.name;
        }
        if (exceptionReason != NULL) {
            *exceptionReason = exception.reason;
        }
        return NO;
    }
}
