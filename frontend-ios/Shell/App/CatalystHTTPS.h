#pragma once
#include <TargetConditionals.h>
#if TARGET_OS_MACCATALYST
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, DMCatalystHTTPSFailure) {
    DMCatalystHTTPSFailureRequest = 1,
    DMCatalystHTTPSFailureCancelled = 2,
};
/// All methods except cancel must run on one serial queue.
@interface DMCatalystHTTPSClient : NSObject
@property(nonatomic, readonly) DMCatalystHTTPSFailure failure;
- (nullable NSData *)fetchURL:(NSURL *)url authorization:(NSString *)authorization maximumBytes:(NSInteger)maximum
    NS_SWIFT_NAME(fetch(_:authorization:maximumBytes:));
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
#endif
