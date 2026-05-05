#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL AWPerformObjCExceptionSafe(void (NS_NOESCAPE ^work)(void),
                                NSString * _Nullable * _Nullable exceptionName,
                                NSString * _Nullable * _Nullable exceptionReason);

NS_ASSUME_NONNULL_END
