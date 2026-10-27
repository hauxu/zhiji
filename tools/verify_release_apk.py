# -*- coding: utf-8 -*-
"""发布前校验：确认 APK 里真的带上了构建设置的服务器地址与证书指纹。

打包时如果漏了 --dart-define，打出来的包连不上服务器（5.16.1~5.16.3 就是这么
翻车的）。所以发布前拿自己的配置跑一遍这个脚本。

用法：
    python tools/verify_release_apk.py <apk> <host> <证书指纹>

host 写构建时用的 ZHIZI_SYNC_HOST，指纹写 ZHIZI_SYNC_CERT（去冒号、小写）。
"""
import hashlib
import sys
import zipfile

if len(sys.argv) < 4:
    print("用法: python tools/verify_release_apk.py <apk> <host> <certSha256>")
    sys.exit(2)

APK = sys.argv[1]
HOST = sys.argv[2].encode()
PIN = sys.argv[3].replace(":", "").lower().encode()

z = zipfile.ZipFile(APK)
libs = [n for n in z.namelist() if n.endswith("libapp.so")]
if not libs:
    print("✗ APK 里没有 libapp.so")
    sys.exit(1)

bad = []
for lib in libs:
    d = z.read(lib)
    has_host = HOST in d
    has_pin = PIN in d
    print(f"  {lib}: 服务器地址={'有' if has_host else '缺失'} "
          f"证书指纹={'有' if has_pin else '缺失'}")
    if not (has_host and has_pin):
        bad.append(lib)

data = open(APK, "rb").read()
sha = hashlib.sha256(data).hexdigest()
print(f"\nAPK: {len(data)} B  sha256={sha}")

if bad:
    print("\n✗ 校验失败：这个包不能用（缺生产参数），别发布")
    sys.exit(2)

print("✓ 校验通过：生产地址与证书指纹都在包里")
# 通过校验后原样返回 0，调用方可据此决定是否发布。
sys.exit(0)