#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Local consistency checks only, not Apple trust, revocation or device eligibility.
// Returns 0 on success, 1 invalid identity, 2 invalid host CMS, 3 signer mismatch.
// On success, writes the P12 leaf certificate in DER form to certificate.
int nx_shell_validate_imported_identity(const unsigned char *pkcs12, size_t pkcs12_size,
    const char *password, const unsigned char *host_cms, size_t host_cms_size,
    unsigned char *certificate, size_t capacity, size_t *certificate_size);
#ifdef __cplusplus
}
#endif
