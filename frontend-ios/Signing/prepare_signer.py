#!/usr/bin/env python3
"""Copy only the pinned MIT zsign native signing core from a local git checkout.
No network, tools execution, credentials, archive library or command-line signer.
"""
import argparse
import io
from pathlib import Path
import subprocess
import tarfile

PIN = "9299685bab7ef99827e06e5dfda93af747386590"
CORE = ["archo", "macho", "openssl", "signing"]
COMMON = ["fs", "json", "log", "sha", "util"]
FILES = ([f"src/{name}.{ext}" for name in CORE for ext in ("cpp", "h")]
         + [f"src/common/{name}.{ext}" for name in COMMON for ext in ("cpp", "h")]
         + ["src/common/common.h", "src/common/mach-o.h"])


def replace_once(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise RuntimeError(f"unexpected pinned source in {path.name}")
    path.write_text(source.replace(old, new))


def prepare(repository, destination):
    # Read immutable git objects, not potentially edited working-tree files.
    archive = subprocess.check_output(["git", "-C", str(repository), "archive", PIN, *FILES, "LICENSE"])
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        for member in source.getmembers():
            if member.name not in FILES + ["LICENSE"]:
                continue
            if not member.isfile():
                raise RuntimeError("expected regular source file")
            relative = member.name.removeprefix("src/")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.extractfile(member).read())
    # Mach-O names are fixed-width byte arrays, not necessarily C strings.
    import re
    archo = destination / "archo.cpp"
    text, count = re.subn(r'strcmp\(("__[^"]+"), (seglc->segname|sect->sectname)\)',
                          r'strncmp(\1, \2, 16)', archo.read_text())
    if count != 8:
        raise RuntimeError("unexpected Mach-O name comparisons in pinned source")
    archo.write_text(text)
    # The upstream CLI exits after signing. An embedded library needs ownership
    # cleanup on success and initialization failure, including its private key.
    replace_once(destination / "openssl.h", "\tZSignAsset();", "\tZSignAsset();\n\t~ZSignAsset();")
    replace_once(destination / "openssl.cpp", "bool ZSignAsset::Init(", """ZSignAsset::~ZSignAsset() {
    EVP_PKEY_free((EVP_PKEY*)m_evpPKey);
    X509_free((X509*)m_x509Cert);
    sk_X509_pop_free((STACK_OF(X509)*)m_caCerts, X509_free);
}

bool ZSignAsset::Init(""")
    replace_once(destination / "openssl.cpp", "\tEVP_PKEY* evpPKey = NULL;", """\tEVP_PKEY* evpPKey = NULL;
    struct TemporaryIdentity {
        X509*& cert; EVP_PKEY*& key; bool transferred = false;
        ~TemporaryIdentity() { if (!transferred) { X509_free(cert); EVP_PKEY_free(key); } }
    } temporaryIdentity{x509Cert, evpPKey};""")
    replace_once(destination / "openssl.cpp", "\tm_evpPKey = evpPKey;", "\ttemporaryIdentity.transferred = true;\n\tm_evpPKey = evpPKey;")
    # A P12's paired key/certificate alone is not proof it belongs to this profile.
    replace_once(destination / "openssl.cpp", "\ttemporaryIdentity.transferred = true;", """
    char team[256] = {};
    int teamLength = X509_NAME_get_text_by_NID(X509_get_subject_name(x509Cert),
                                              NID_organizationalUnitName, team, sizeof(team));
    if (teamLength <= 0 || teamLength >= sizeof(team) || m_strTeamId != team ||
        X509_cmp_current_time(X509_get0_notBefore(x509Cert)) >= 0 ||
        X509_cmp_current_time(X509_get0_notAfter(x509Cert)) <= 0) return false;
    int certificateLength = i2d_X509(x509Cert, NULL);
    if (certificateLength <= 0 || certificateLength > 1024 * 1024) return false;
    string certificate(certificateLength, '\\0');
    auto *der = reinterpret_cast<unsigned char*>(&certificate[0]);
    if (i2d_X509(x509Cert, &der) != certificateLength) return false;
    bool member = false;
    for (size_t i = 0; i < jvProv["DeveloperCertificates"].size(); ++i) {
        if (jvProv["DeveloperCertificates"][i].as_data() == certificate) member = true;
    }
    if (!member) return false;
    temporaryIdentity.transferred = true;""")
    replace_once(destination / "openssl.cpp", "ERR_print_errors_fp(stdout);", "ERR_clear_error();")
    # CMS objects retain the signing key. RAII must release them on every return.
    crypto = destination / "openssl.cpp"
    source = crypto.read_text()
    start = source.index("bool ZSignAsset::GenerateCMS(void*")
    end = source.index("bool ZSignAsset::GetCertSubjectCN(void*", start)
    region = source[start:end]
    declarations = [
        ("BIO* in = BIO_new_mem_buf(strCDHashData.c_str(), (int)strCDHashData.size());", "BIO", "in", "BIO_free"),
        ("BIO* in = BIO_new(BIO_s_mem());", "BIO", "in", "BIO_free"),
        ("BIO* out = BIO_new(BIO_s_mem());", "BIO", "out", "BIO_free"),
        ("CMS_ContentInfo* cms = CMS_sign(NULL, NULL, otherCerts, NULL, nFlags);", "CMS_ContentInfo", "cms", "CMS_ContentInfo_free"),
        ("CMS_ContentInfo* cms = d2i_CMS_bio(in, NULL);", "CMS_ContentInfo", "cms", "CMS_ContentInfo_free"),
        ('ASN1_OBJECT* obj = OBJ_txt2obj("1.2.840.113635.100.9.1", 1);', "ASN1_OBJECT", "obj", "ASN1_OBJECT_free"),
        ('ASN1_OBJECT* obj2 = OBJ_txt2obj("1.2.840.113635.100.9.2", 1);', "ASN1_OBJECT", "obj2", "ASN1_OBJECT_free"),
        ("X509_ATTRIBUTE* attr = X509_ATTRIBUTE_new();", "X509_ATTRIBUTE", "attr", "X509_ATTRIBUTE_free"),
        ("ASN1_TYPE* type_256 = (ASN1_TYPE*)GenerateASN1Type(sha256);", "ASN1_TYPE", "type_256", "ASN1_TYPE_free"),
    ]
    for declaration, kind, name, cleanup in declarations:
        if region.count(declaration) != 1:
            raise RuntimeError("unexpected CMS allocation in pinned source")
        region = region.replace(declaration, declaration +
            f"\n    std::unique_ptr<{kind}, decltype(&{cleanup})> owned_{name}({name}, {cleanup});")
    region = region.replace("\tASN1_TYPE_free(type_256);", "")
    region = region.replace("\tsk_X509_pop_free(otherCerts, X509_free); // CMS_sign holds its own references", "")
    declaration = "STACK_OF(X509)* otherCerts = sk_X509_new_null();"
    region = region.replace(declaration, declaration + """
    auto freeStack = [](STACK_OF(X509)* stack) { sk_X509_pop_free(stack, X509_free); };
    std::unique_ptr<STACK_OF(X509), decltype(freeStack)> ownedChain(otherCerts, freeStack);""")
    crypto.write_text(source[:start] + region + source[end:])
    # Always unmap failed operations. Upstream Free() clears the mapping before
    # closing it, and its destructor only releases architecture descriptors.
    replace_once(destination / "macho.cpp", "ZMachO::~ZMachO()\n{\n\tFreeArchOes();\n}",
                 "ZMachO::~ZMachO()\n{\n\tCloseFile();\n\tFreeArchOes();\n}")
    replace_once(destination / "macho.cpp", "\tFreeArchOes();\n\treturn CloseFile();",
                 "\tbool closed = CloseFile();\n\tFreeArchOes();\n\treturn closed;")
    replace_once(destination / "macho.cpp", "\treturn true;\n}\n\nvoid ZMachO::PrintInfo()",
                 "\tm_pBase = NULL;\n\tm_sSize = 0;\n\treturn true;\n}\n\nvoid ZMachO::PrintInfo()")
    replace_once(destination / "macho.cpp", "if (!archo->m_bEnoughSpace && !m_bCSRealloced)",
                 "if (false && !archo->m_bEnoughSpace && !m_bCSRealloced)")
    # The pinned Apple XCFramework uses the case-sensitive OpenSSL framework
    # namespace. Keep system OpenSSL includes for the Linux crypto regression.
    includes = 0
    for source in destination.rglob("*.cpp"):
        text, count = re.subn(r'#include <openssl/([^>]+)>',
            r'#if defined(__APPLE__)\n#include <OpenSSL/\1>\n#else\n#include <openssl/\1>\n#endif', source.read_text())
        includes += count
        source.write_text(text)
    if includes != 8:
        raise RuntimeError("unexpected OpenSSL includes in pinned source")
    for source in destination.rglob("*"):
        if source.is_file():
            source.write_text("\n".join(re.sub(r"^[ \t]+", lambda m: m[0].expandtabs(4), line).rstrip() for line in source.read_text().splitlines()).rstrip() + "\n")
    (destination / "UPSTREAM.txt").write_text(
        f"https://github.com/zhlynn/zsign\nCommit: {PIN}\nMIT, see LICENSE.\n"
        "Local adaptations: identity/CMS/mapping cleanup, quiet errors, bounded names, certificate/profile checks, Apple framework header casing, whitespace normalization, no signature resizing.\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--output", type=Path, help="Generate into a new directory instead of checking committed sources")
    args = parser.parse_args()
    if args.output:
        prepare(args.repository, args.output)
    else:
        import tempfile
        with tempfile.TemporaryDirectory(prefix="shell-signer-check-") as temporary:
            generated = Path(temporary) / "Vendor"
            prepare(args.repository, generated)
            committed = Path(__file__).resolve().parents[1] / "Sources/NativeSigning/Vendor"
            expected = {p.relative_to(generated): p.read_bytes() for p in generated.rglob("*") if p.is_file()}
            actual = {p.relative_to(committed): p.read_bytes() for p in committed.rglob("*") if p.is_file()}
            if expected != actual:
                raise SystemExit("Committed signer differs from the pinned source plus documented adaptations")
            print("PASS: committed signer matches pinned source and adaptations")
