#!/usr/bin/env python3
"""Read-only SHA256, slice and iOS arm64 export validation; no Apple SDK required."""
import hashlib, json, plistlib, struct, sys, zipfile
from pathlib import Path
if len(sys.argv) != 2:
 raise SystemExit('usage: verify_openssl_artifact.py /path/to/OpenSSL.xcframework.zip')
p=Path(sys.argv[1])
digest=hashlib.sha256(p.read_bytes()).hexdigest()
assert digest=='f50188506490c643715489217d32e458d06cee5579399ff616f0ce2038169fea',digest
with zipfile.ZipFile(p) as z:
 info=plistlib.loads(z.read('OpenSSL.xcframework/Info.plist'))
 slices={x['LibraryIdentifier']:x['SupportedArchitectures'] for x in info['AvailableLibraries']}
 for name,arches in {'ios-arm64':['arm64'],'ios-arm64_x86_64-simulator':['arm64','x86_64'],'macos-arm64_x86_64':['arm64','x86_64']}.items():
  assert slices[name]==arches
 b=z.read('OpenSSL.xcframework/ios-arm64/OpenSSL.framework/OpenSSL')
 assert struct.unpack_from('<I',b)[0]==0xfeedfacf
 ncmds=struct.unpack_from('<I',b,16)[0]; offset=32; exports=set()
 for _ in range(ncmds):
  cmd,size=struct.unpack_from('<II',b,offset)
  if cmd==2:
   symoff,nsyms,stroff,strsize=struct.unpack_from('<IIII',b,offset+8)
   for j in range(nsyms):
    index,kind,section,desc,value=struct.unpack_from('<IBBHQ',b,symoff+j*16)
    name=b[stroff+index:b.find(b'\0',stroff+index)].decode(errors='replace')
    if kind & 1 and kind & 0x0e == 0x0e and section:
     exports.add(name)
  offset+=size
 required={'_CMS_sign','_PKCS12_parse','_OSSL_PROVIDER_load','_OSSL_PROVIDER_add_builtin','_ossl_legacy_provider_init'}
 assert required <= exports,required-exports
 print(json.dumps({'archive':str(p),'bytes':p.stat().st_size,'sha256':digest,'slices':slices,'verified_defined_exports':sorted(required),'runtime_tested':False},indent=2))
