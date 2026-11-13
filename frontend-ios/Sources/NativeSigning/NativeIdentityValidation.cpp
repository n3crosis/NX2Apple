#include "NativeIdentityValidation.h"
#if defined(__APPLE__)
#include <OpenSSL/cms.h>
#include <OpenSSL/pkcs12.h>
#include <OpenSSL/x509.h>
#include <OpenSSL/provider.h>
#else
#include <openssl/cms.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <openssl/provider.h>
#endif
#include <memory>
#include <mutex>
#include <vector>

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
#if defined(__APPLE__)
// The pinned OpenSSL Apple framework includes the legacy provider statically.
extern "C" OSSL_provider_init_fn ossl_legacy_provider_init;
#endif
static void initializeIdentityProviders() {
    static std::once_flag once;
    std::call_once(once, [] {
#if defined(__APPLE__)
        OSSL_PROVIDER_add_builtin(nullptr, "legacy", ossl_legacy_provider_init);
#endif
        // Keep these providers loaded for the process lifetime. Loading legacy
        // disables implicit default-provider loading, so load default explicitly.
        // No credential data or key material is retained by this initialization.
        OSSL_PROVIDER_load(nullptr, "default");
        OSSL_PROVIDER_load(nullptr, "legacy");
    });
}
#endif

int nx_shell_validate_imported_identity(const unsigned char *pkcs12, size_t pkcs12_size,
    const char *password, const unsigned char *host_cms, size_t host_cms_size,
    unsigned char *certificate, size_t capacity, size_t *certificate_size) {
    if (certificate_size) *certificate_size = 0;
    if (!pkcs12 || !pkcs12_size || pkcs12_size > 1024 * 1024 || !password ||
        !certificate || !certificate_size) return 1;
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
    initializeIdentityProviders();
#endif
    const unsigned char *cursor = pkcs12;
    std::unique_ptr<PKCS12, decltype(&PKCS12_free)> p12(
        d2i_PKCS12(nullptr, &cursor, static_cast<long>(pkcs12_size)), PKCS12_free);
    if (!p12 || cursor != pkcs12 + pkcs12_size) return 1;
    EVP_PKEY *raw_key = nullptr;
    X509 *raw_cert = nullptr;
    const int parsed = PKCS12_parse(p12.get(), password, &raw_key, &raw_cert, nullptr);
    std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> key(raw_key, EVP_PKEY_free);
    std::unique_ptr<X509, decltype(&X509_free)> cert(raw_cert, X509_free);
    if (parsed != 1 || !key || !cert || X509_check_private_key(cert.get(), key.get()) != 1 ||
        X509_cmp_current_time(X509_get0_notBefore(cert.get())) >= 0 ||
        X509_cmp_current_time(X509_get0_notAfter(cert.get())) <= 0) return 1;
    if (!host_cms || !host_cms_size || host_cms_size > 16 * 1024 * 1024) return 2;
    cursor = host_cms;
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(
        d2i_CMS_ContentInfo(nullptr, &cursor, static_cast<long>(host_cms_size)), CMS_ContentInfo_free);
    if (!cms || cursor != host_cms + host_cms_size) return 2;
    // Match SignerInfo to embedded certificates. Do not pick the first certificate
    // in the bag, which may be an intermediate or unrelated certificate.
    if (CMS_set1_signers_certs(cms.get(), nullptr, 0) != 1) return 2;
    STACK_OF(X509) *signers = CMS_get0_signers(cms.get());
    if (!signers) return 2;
    const int count = sk_X509_num(signers);
    X509 *signer = count == 1 ? sk_X509_value(signers, 0) : nullptr;
    const int size = i2d_X509(cert.get(), nullptr);
    const int signer_size = signer ? i2d_X509(signer, nullptr) : -1;
    bool equal = false;
    if (size > 0 && signer_size == size) {
        std::vector<unsigned char> imported(size), installed(size);
        auto *a = imported.data();
        auto *b = installed.data();
        equal = i2d_X509(cert.get(), &a) == size && i2d_X509(signer, &b) == size && imported == installed;
    }
    sk_X509_free(signers); // Certificates remain owned by CMS_ContentInfo.
    if (!signer) return 2;
    if (!equal) return 3;
    if (static_cast<size_t>(size) > capacity) return 1;
    auto *output = certificate;
    if (i2d_X509(cert.get(), &output) != size) return 1;
    *certificate_size = static_cast<size_t>(size);
    return 0;
}
