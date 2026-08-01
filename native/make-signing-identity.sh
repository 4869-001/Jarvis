#!/bin/bash
#
# 造一个本地代码签名身份，让 Jarvis.app 的签名在重新构建后保持不变。
#
# 为什么需要：ad-hoc 签名（codesign -s -）的 designated requirement 是
#   cdhash H"<二进制的哈希>"
# 二进制一改哈希就变，TCC 里存的辅助功能/自动化授权立刻作废——而系统设置里那个
# 开关**看着还是开的**，`AXIsProcessTrusted()` 却返回 false。症状是"明明给了权限，
# 播放器还是控制不了"，每 build 一次复发一次。
#
# 用自签证书签之后 requirement 变成
#   identifier "com.jarvis.desktop" and certificate leaf = H"<证书哈希>"
# 只跟证书绑定，重新构建不影响，授权一次就够。
#
# 幂等：身份已存在就直接退出。
#
set -euo pipefail

NAME="Jarvis Local Dev"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  # 花括号不能省：紧跟着的「」是多字节字符，bash 会把它算进变量名，set -u 下直接报错
  echo "✓ 签名身份「${NAME}」已存在，无需重建"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = Jarvis Local Dev
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
CNF

echo "▸ 生成自签证书（10 年）"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -name "$NAME" -passout pass:jarvis 2>/dev/null

echo "▸ 导入登录钥匙串"
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P jarvis -T /usr/bin/codesign

echo "▸ 标记为可信任的代码签名证书"
# 用户域信任，不需要 sudo；加 -d 写系统域才要管理员
security add-trusted-cert -r trustRoot -p codeSign "$WORK/cert.pem"

security find-identity -v -p codesigning | grep "$NAME"
echo "✓ 完成。接下来 ./native/build.sh 会自动用这个身份签名。"
echo "  首次换签名后要去系统设置 → 隐私与安全性 → 辅助功能，把 J.A.R.V.I.S. 关掉再打开一次。"
