#!/bin/sh
set -eu

if pgrep -x ChatGPT >/dev/null 2>&1 || pgrep -x Codex >/dev/null 2>&1; then
  echo 'Önce Codex/ChatGPT masaüstü uygulamasındaki işleri tamamlayıp uygulamadan çıkın.' >&2
  exit 2
fi
desktop_app=/Applications/ChatGPT.app
test -d "$desktop_app" || desktop_app=/Applications/Codex.app
test -d "$desktop_app" || { echo 'Codex masaüstü uygulaması bulunamadı.' >&2; exit 1; }
relay=/Applications/yusufiwt.app/Contents/Resources/codex-desktop-relay
hook=/Applications/yusufiwt.app/Contents/MacOS/agentcontrol-hook
test -x "$relay" || { echo 'Önce güncel yusufiwt sürümünü kurun.' >&2; exit 1; }
open --env "CODEX_CLI_PATH=$relay" --env CODEX_APP_SERVER_FORCE_CLI=1 \
  --env "YUSUFIWT_CODEX_EXECUTABLE=$desktop_app/Contents/Resources/codex" "$desktop_app"
attempt=0
while test "$attempt" -lt 20; do
  if "$hook" codex-desktop-status >/dev/null 2>&1; then
    echo 'Codex yerel kontrol bağlantısı doğrulandı. Canlı durdurma testi yapılabilir.'
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 1
done
echo 'Codex açıldı ancak yerel kontrol bağlantısı doğrulanamadı. Bu çıktı başarı anlamına gelmez.' >&2
exit 3
