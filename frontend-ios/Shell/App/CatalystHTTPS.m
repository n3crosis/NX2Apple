#include "CatalystHTTPS.h"
#if TARGET_OS_MACCATALYST
#include <curl/curl.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

struct DMHTTPSBody {
    __unsafe_unretained NSMutableData *data;
    NSUInteger maximum;
    atomic_bool *cancelled;
};
static size_t dm_https_write(char *bytes, size_t size, size_t count, void *opaque) {
    struct DMHTTPSBody *body = opaque;
    if (atomic_load_explicit(body->cancelled, memory_order_relaxed) ||
        (size && count > SIZE_MAX / size)) return 0;
    size_t length = size * count;
    if (body->data.length > body->maximum || length > body->maximum - body->data.length) return 0;
    [body->data appendBytes:bytes length:length];
    return length;
}
static int dm_https_progress(void *opaque, curl_off_t total, curl_off_t current, curl_off_t sentTotal, curl_off_t sent) {
    return atomic_load_explicit((atomic_bool *)opaque, memory_order_relaxed) ? 1 : 0;
}

@implementation DMCatalystHTTPSClient {
    CURL *_easy;
    atomic_bool _cancelled;
    NSString *_origin;
    DMCatalystHTTPSFailure _failure;
}
- (instancetype)init {
    if ((self = [super init])) {
        atomic_init(&_cancelled, false);
        static dispatch_once_t once;
        static CURLcode initialized;
        dispatch_once(&once, ^{ initialized = curl_global_init(CURL_GLOBAL_DEFAULT); });
        if (initialized == CURLE_OK) _easy = curl_easy_init();
    }
    return self;
}
- (void)dealloc { if (_easy) curl_easy_cleanup(_easy); }
- (void)cancel { atomic_store_explicit(&_cancelled, true, memory_order_relaxed); }
- (DMCatalystHTTPSFailure)failure { return _failure; }
- (NSData *)fetchURL:(NSURL *)url authorization:(NSString *)authorization maximumBytes:(NSInteger)maximum {
    _failure = DMCatalystHTTPSFailureRequest;
    if (atomic_load_explicit(&_cancelled, memory_order_relaxed)) {
        _failure = DMCatalystHTTPSFailureCancelled;
        return nil;
    }
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!_easy || ![parts.scheme.lowercaseString isEqualToString:@"https"] || !parts.host.length ||
        parts.user != nil || parts.password != nil || parts.fragment != nil ||
        maximum <= 0 || maximum > 16 * 1024 * 1024 || authorization.length != 64 ||
        [authorization rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) return nil;
    NSString *origin = [NSString stringWithFormat:@"%@:%@", parts.host.lowercaseString, parts.port ?: @443];
    if (_origin && ![_origin isEqualToString:origin]) return nil;
    _origin = origin;
    NSMutableData *data = [NSMutableData data];
    struct DMHTTPSBody body = { data, (NSUInteger)maximum, &_cancelled };
    NSString *header = [@"Authorization: Bearer " stringByAppendingString:authorization];
    struct curl_slist *headers = curl_slist_append(NULL, header.UTF8String);
    if (!headers) return nil;
    CURLcode result = CURLE_FAILED_INIT;
    long status = 0;
    // Reset request options, not the easy handle's connection/TLS-session cache.
    curl_easy_reset(_easy);
#define DM_OPT(option, value) do { if (curl_easy_setopt(_easy, option, value) != CURLE_OK) goto finished; } while (0)
    DM_OPT(CURLOPT_URL, url.absoluteString.UTF8String);
    DM_OPT(CURLOPT_HTTPHEADER, headers);
    DM_OPT(CURLOPT_HTTPGET, 1L);
    DM_OPT(CURLOPT_PROTOCOLS, (long)CURLPROTO_HTTPS);
    DM_OPT(CURLOPT_REDIR_PROTOCOLS, (long)CURLPROTO_HTTPS);
    DM_OPT(CURLOPT_FOLLOWLOCATION, 0L);
    DM_OPT(CURLOPT_MAXREDIRS, 0L);
    DM_OPT(CURLOPT_SSL_VERIFYPEER, 1L);
    DM_OPT(CURLOPT_SSL_VERIFYHOST, 2L);
    DM_OPT(CURLOPT_NOSIGNAL, 1L);
    DM_OPT(CURLOPT_CONNECTTIMEOUT, 15L);
    DM_OPT(CURLOPT_TIMEOUT, 60L);
    DM_OPT(CURLOPT_PROXY, ""); // Do not leak Authorization through inherited proxy environment variables.
    DM_OPT(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    DM_OPT(CURLOPT_VERBOSE, 0L);
    DM_OPT(CURLOPT_WRITEFUNCTION, dm_https_write);
    DM_OPT(CURLOPT_WRITEDATA, &body);
    DM_OPT(CURLOPT_NOPROGRESS, 0L);
    DM_OPT(CURLOPT_XFERINFOFUNCTION, dm_https_progress);
    DM_OPT(CURLOPT_XFERINFODATA, &_cancelled);
    result = curl_easy_perform(_easy);
    if (result == CURLE_OK && curl_easy_getinfo(_easy, CURLINFO_RESPONSE_CODE, &status) != CURLE_OK) result = CURLE_FAILED_INIT;
finished:
#undef DM_OPT
    // Clear borrowed stack/header pointers before releasing their storage.
    curl_easy_setopt(_easy, CURLOPT_HTTPHEADER, NULL);
    curl_easy_setopt(_easy, CURLOPT_WRITEDATA, NULL);
    curl_easy_setopt(_easy, CURLOPT_XFERINFODATA, NULL);
    curl_slist_free_all(headers);
    if (atomic_load_explicit(&_cancelled, memory_order_relaxed)) {
        _failure = DMCatalystHTTPSFailureCancelled;
        return nil;
    }
    if (result != CURLE_OK || status != 200) return nil;
    return data;
}
@end
#endif
