#!/bin/zsh
# 在本机模拟一台「干净的机器」跑 e2e-clean.js：空的主目录（Foundation 的 CFFIXED_USER_HOME + HOME）、最小的 PATH，
# 网页存储本来就是测试专用的。不动你自己的设置、会话和 CLI 配置。
#   tools/uitest/clean-machine.sh none   一个 CLI 都没装
#   tools/uitest/clean-machine.sh path   CLI 装在登录 shell 的 PATH 里（像 nvm 那样，用你本机的可执行文件做软链接），但都没登录
set -euo pipefail
HERE="${0:A:h}"; SCENE=${1:-none}
H=$(mktemp -d -t aipethub-cleanhome); H=${H:A}
if [[ $SCENE == path ]]; then
  mkdir -p "$H/fakebin"
  for c in claude codex agy dsh; do
    src=$(zsh -lc "command -v $c" 2>/dev/null || true)
    [[ -n $src ]] && ln -s "$src" "$H/fakebin/$c"
  done
  print "export PATH=\"$H/fakebin:\$PATH\"" > "$H/.zprofile"
fi
echo "模拟的主目录：$H"
env -i HOME="$H" CFFIXED_USER_HOME="$H" USER="$USER" LOGNAME="$LOGNAME" SHELL=/bin/zsh TMPDIR="$TMPDIR" LANG=zh_CN.UTF-8 \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin REAL=1 "$HERE/run.sh" claude e2e-clean.js "$SCENE" 400
echo "模拟的主目录留着备查：$H（里面是 CLI 没登录时生成的空配置，可以删）"
