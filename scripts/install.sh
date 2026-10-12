#!/usr/bin/env bash
# ============================================================
# EVREN LLM + OpenCode kurulumu (Linux / macOS) — v2 uyumlu
#
#   ./install.sh                kurulum (tek tık)
#   ./install.sh --set-key      anahtarı yenile (config/plugin'a dokunmadan)
#   ./install.sh --sync-models  model listesini API'den tazele
#   ./install.sh --uninstall    tüm değişiklikleri geri al
#   ./install.sh --diagnose     salt-okunur teşhis (anahtar ASLA yazdırılmaz)
#
# Güvenlik:
#   - API anahtarı opencode.jsonc'ye YAZILMAZ (değer olarak da,
#     {env:} referansı olarak da config'e anahtar konmaz).
#   - Tek kaynak: ~/.config/opencode/.evren-config (JSON, chmod 600).
#   - Config'deki provider bloğu v2 şemasını kullanır:
#       providers.evren = { name, env:[...], package, settings:{baseURL} }
#     kimlik plugin üzerinden dosya/env'den çözülür.
#   - Legacy kalıntılar (.evren-key, kalıcı RC export satırları)
#     kurulumda içe aktarılıp temizlenir.
# ============================================================
set -euo pipefail

BASE_URL="https://evren-llmapi.ssyz.org.tr/v1"
INSTALLER_VERSION="0.1.8"
REPO_RAW="https://raw.githubusercontent.com/grayishsun/opencode-for-evren/main"
CONFIG_DIR="${HOME}/.config/opencode"
CONFIG_PATH="${CONFIG_DIR}/opencode.jsonc"
KEY_FILE="${CONFIG_DIR}/.evren-config"
LEGACY_KEY_FILE="${CONFIG_DIR}/.evren-key"
LEGACY_HOME_KEY="${HOME}/.evren-config"
PLUGIN_DIR="${CONFIG_DIR}/plugins/evren"
# Kurulum düzeni DÜZDÜR (package.json + index.ts + rpc.ts + tui.tsx kökte):
# opencode dosya-keşfi yalnızca kök index.ts'i yükler, src/ alt dizinini görmez.
PLUGIN_FILES=("plugin/package.json" "plugin/index.ts" "plugin/rpc.ts" "plugin/tui.tsx")

fail() { printf '\nHATA: %s\n' "$1" >&2; exit 1; }
ok()   { printf '[OK] %s\n' "$1"; }
info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[UYARI] %s\n' "$1"; }

command -v curl >/dev/null 2>&1 || fail "curl bulunamadı."
command -v python3 >/dev/null 2>&1 || fail "python3 gerekli (JSON birleştirme için)."

# OpenCode v2 zorunludur (service restart, providers şeması, plugin API).
# Kurulu değilse kurulum adımı halleder; v1 ise durup yükseltme yönergesi verir.
require_v2() {
  command -v opencode >/dev/null 2>&1 || return 0
  local ver major
  ver="$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  major="${ver%%.*}"
  if [[ -z "$major" || "$major" -lt 2 ]]; then
    fail "Bu kurulum OpenCode v2 gerektirir (tespit edilen: ${ver:-bilinmiyor}). Yükseltmek için 'opencode upgrade' çalıştırın ya da https://opencode.ai adresinden yeniden kurun."
  fi
}

# Script'in yanındaki plugin/ varsa yerelden, yoksa GitHub'dan çekilir.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../plugin/index.ts" || -f "${SCRIPT_DIR}/plugin/index.ts" ]]; then
  SRC_MODE="local"
  if [[ -f "${SCRIPT_DIR}/plugin/index.ts" ]]; then SRC_DIR="${SCRIPT_DIR}/plugin"; else SRC_DIR="${SCRIPT_DIR}/../plugin"; fi
else
  SRC_MODE="remote"
fi

# --- HTTP: 429'da 6sn bekleyip en fazla 4 deneme, çift başlık ---
api_get() {
  local path="$1" key="$2" attempt=1 code body tmp
  tmp="$(mktemp)"
  while (( attempt <= 4 )); do
    code="$(curl -sS --max-time 30 -o "$tmp" -w '%{http_code}' \
      "${BASE_URL}${path}" \
      -H "X-API-Key: ${key}" \
      -H "Authorization: Bearer ${key}")" || code="000"
    if [[ "$code" == "429" && "$attempt" -lt 4 ]]; then
      sleep 6
      attempt=$(( attempt + 1 ))
      continue
    fi
    if [[ "$code" != "200" ]]; then
      rm -f "$tmp"
      fail "API çağrısı başarısız: GET ${path} -> HTTP ${code}"
    fi
    cat "$tmp"
    rm -f "$tmp"
    return 0
  done
}

mask_key() {
  python3 -c 'import sys; k=sys.argv[1]; print("evren_llm_…" + k[-4:] if len(k) > 8 else "(geçersiz)")' "$1"
}

# Yapıştırma artıklarını temizler: kırp, tırnakları ve görünmez karakterleri at.
clean_key() {
  python3 -c 'import sys; k = sys.stdin.read().strip(); k = k.strip(chr(34) + chr(39)); k = k.replace(chr(0x200b), "").replace(chr(0x200c), "").replace(chr(0x200d), "").replace(chr(0xfeff), ""); print(k)'
}

# Anahtarı gizli sorar, temizler, gevşek biçimi denetler. Sonucu stdout'a basar.
# Gerçek doğrulama canlı API çağrısıdır (401).
prompt_key() {
  local label="${1:-EVREN API anahtarınız (evren_llm_...)}" key=""
  if [[ -r /dev/tty ]]; then
    IFS= read -r -s -p "$label: " key 2>/dev/null </dev/tty || true
  fi
  if [[ -z "$key" ]]; then
    # tty yoksa stdin'den oku (pipe ile otomasyon ya da normal terminal).
    IFS= read -r -s -p "$label: " key || true
  fi
  printf '\n' >&2
  key="$(printf '%s' "$key" | clean_key)"
  [[ "$key" =~ ^evren_llm_[^[:space:]]{8,}$ ]] \
    || fail "Anahtar biçimi tanınmadı (uzunluk ${#key}). Tırnaksız, 'evren_llm_' ile başlayan anahtarı panelden yeniden kopyalayın."
  printf '%s' "$key"
}

read_saved_key() {
  python3 - "$KEY_FILE" "$LEGACY_KEY_FILE" "$LEGACY_HOME_KEY" <<'PYEOF'
import sys, json, os
for path in sys.argv[1:]:
    try:
        if not os.path.isfile(path):
            continue
        raw = open(path, encoding="utf-8").read().strip()
        if not raw:
            continue
        if raw.startswith("{"):
            data = json.loads(raw)
            key = str(data.get("apiKey") or data.get("key") or "").strip()
        else:
            key = raw
        if key:
            print(key)
            sys.exit(0)
    except Exception:
        continue
sys.exit(1)
PYEOF
}

write_key_file() {
  local key="$1"
  mkdir -p "$CONFIG_DIR"
  python3 - "$KEY_FILE" "$key" <<'PYEOF'
import sys, json, os
path, key = sys.argv[1], sys.argv[2]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump({"apiKey": key, "updatedAt": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()}, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
os.chmod(path, 0o600)
PYEOF
  chmod 600 "$KEY_FILE"
  ok "Anahtar $KEY_FILE dosyasına yazıldı (chmod 600)."
  # Legacy tek-satır .evren-key varsa içe aktarıldı, artık silinir.
  rm -f "$LEGACY_KEY_FILE"
}

backup_config() {
  if [[ -f "$CONFIG_PATH" ]]; then
    local bak="${CONFIG_PATH}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_PATH" "$bak"
    info "Config yedeklendi: $bak"
  fi
}

# API /v1/models yanıtından opencode models haritası üretir.
build_models_map() {
  python3 <<'PYEOF'
import sys, json
payload = json.load(sys.stdin)
models = {}
for m in payload.get("data", []):
    mid = m.get("id")
    if not mid or m.get("task") not in ("chat", "vision_chat"):
        continue
    ctx = m.get("context_length") or 200000
    out = m.get("default_max_output_tokens") or min(8192, ctx)
    mods = [x for x in (m.get("modalities") or ["text"]) if x in ("text", "image")] or ["text"]
    caps = m.get("capabilities") or {}
    models[mid] = {
        "name": mid,
        "capabilities": {"tools": caps.get("tools") is True, "input": mods, "output": ["text"]},
        "limit": {"context": ctx, "output": out},
    }
if not models:
    print("HATA: API seçilebilir sohbet modeli döndürmedi.", file=sys.stderr)
    sys.exit(1)
print(json.dumps(models, ensure_ascii=False))
PYEOF
}

# Gömülü yedek liste (2026-10-12 /v1/models değerleri). API hatsında kullanılır.
fallback_models_map() {
  python3 <<'PYEOF'
import json
fb = [
  ("glm-5.3", 524288, 16384, ["text"], True),
  ("deepseek-v4.1-flash", 1048576, 65536, ["text", "image"], True),
  ("deepseek-v4-flash", 1048576, 16384, ["text"], True),
  ("qwen3.8-flash-next", 262144, 16384, ["text", "image"], True),
  ("gemma-4-31b", 262144, 16384, ["text", "image"], True),
  ("qwen3-vl-30b", 262144, 16384, ["text", "image"], True),
  ("mimo-v2.6-pro", 1048576, 16384, ["text", "image"], True),
  ("auto", 32768, 16384, ["text"], False),
]
print(json.dumps({mid: {"name": mid,
  "capabilities": {"tools": t, "input": mo, "output": ["text"]},
  "limit": {"context": c, "output": o}} for mid, c, o, mo, t in fb}, ensure_ascii=False))
PYEOF
}

# opencode.jsonc birleştirme: providers.evren v2 şeması, anahtar ASLA yazılmaz.
merge_config() {
  local models_json="$1"
  mkdir -p "$CONFIG_DIR"
  MODELS_MAP_JSON="$models_json" python3 - "$CONFIG_PATH" <<'PYEOF'
import sys, json, os, re
from datetime import datetime
config_path = sys.argv[1]
models_map = json.loads(os.environ["MODELS_MAP_JSON"])
os.makedirs(os.path.dirname(config_path), exist_ok=True)

evren_block = {
    "name": "EVREN LLM",
    "env": ["EVREN_API_KEY", "EVREN_LLM_API_KEY"],
    "package": "@opencode/ai/providers/openai-compatible",
    "settings": {"baseURL": "https://evren-llmapi.ssyz.org.tr/v1"},
    "models": models_map,
}

cfg = {}
if os.path.isfile(config_path):
    raw = open(config_path, encoding="utf-8").read()
    raw = re.sub(r'(?m)^\s*//.*$', '', raw)
    raw = re.sub(r'/\*[\s\S]*?\*/', '', raw)
    raw = re.sub(r',\s*([}\]])', r'\1', raw)
    try:
        cfg = json.loads(raw)
    except Exception:
        cfg = {}

# v1 şemadan kalan provider.evren bloğu v2'ye taşınır (apiKey düşürülür).
legacy = (cfg.get("provider") or {}).pop("evren", None)
if "provider" in cfg and not cfg["provider"]:
    del cfg["provider"]

cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg.setdefault("providers", {})
cfg["providers"]["evren"] = evren_block

def pick_default():
    for cand in ("glm-5.3", "auto"):
        if cand in models_map:
            return f"evren/{cand}"
    return f"evren/{next(iter(models_map))}"

def pick_small():
    if "deepseek-v4.1-flash" in models_map:
        return "evren/deepseek-v4.1-flash"
    smallest = min(models_map.items(), key=lambda kv: kv[1].get("limit", {}).get("context", 0))
    return f"evren/{smallest[0]}"

cur = cfg.get("model", "")
if not cur or (cur.startswith("evren/") and cur.split("/", 1)[1] not in models_map):
    cfg["model"] = pick_default()
cur_small = cfg.get("small_model", "")
if not cur_small or (cur_small.startswith("evren/") and cur_small.split("/", 1)[1] not in models_map):
    cfg["small_model"] = pick_small()

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"[OK] opencode.jsonc güncellendi ({len(models_map)} model, apiKey yazılmadı)")
PYEOF
}

# sha256: sha256sum (Linux) ya da shasum -a 256 (macOS). LF-normalize uygular.
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    tr -d '\r' < "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    tr -d '\r' < "$1" | shasum -a 256 | cut -d' ' -f1
  else
    return 1
  fi
}

install_plugin() {
  mkdir -p "$PLUGIN_DIR"
  if [[ "$SRC_MODE" == "local" ]]; then
    cp "${SRC_DIR}/package.json" "${SRC_DIR}/index.ts" "${SRC_DIR}/rpc.ts" "${SRC_DIR}/tui.tsx" "$PLUGIN_DIR/"
  else
    local sums f base want got
    sums="$(mktemp)"
    curl -fsS --max-time 60 --retry 3 "${REPO_RAW}/SHA256SUMS" -o "$sums" \
      || fail "SHA256SUMS indirilemedi."
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
      || fail "Bütünlük doğrulaması için sha256sum ya da shasum gerekli."
    for f in "${PLUGIN_FILES[@]}"; do
      base="$(basename "$f")"
      curl -fsS --max-time 60 --retry 3 "${REPO_RAW}/${f}" -o "${PLUGIN_DIR}/${base}" \
        || fail "Plugin dosyası indirilemedi: $f"
      want="$(grep -F "  $f" "$sums" | head -n1 | cut -d' ' -f1)"
      [[ -n "$want" ]] || fail "SHA256SUMS içinde kayıt yok: $f"
      got="$(sha_of "${PLUGIN_DIR}/${base}")"
      [[ "$got" == "$want" ]] || fail "Bütünlük doğrulanamadı: $f (indirilen dosya beklenenden farklı)"
    done
    rm -f "$sums"
    ok "Plugin bütünlüğü doğrulandı (SHA256)."
  fi
  # Eski düzen artıkları (src/ alt dizini) yeni paketi gölgelerdi; temizlenir.
  rm -rf "${PLUGIN_DIR}/src"
  rm -f "${PLUGIN_DIR}/index.js" "${PLUGIN_DIR}/tui.ts"
  ok "Plugin kuruldu: $PLUGIN_DIR"
}

terms_flow() {
  local key="$1" status version accepted
  status="$(api_get "/terms/status" "$key")"
  version="$(printf '%s' "$status" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("current_version", ""))')"
  accepted="$(printf '%s' "$status" | python3 -c 'import sys,json; print(str(json.load(sys.stdin).get("accepted", False)))')"
  [[ -n "$version" ]] || fail "terms/status okunamadı."
  if [[ "$accepted" != "True" ]]; then
    local text
    text="$(api_get "/terms/text" "$key")"
    printf '\n=== EVREN Kullanım Şartları (v%s) ===\n' "$version"
    printf '%s' "$text" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("content", ""))'
    printf '\n'
    local confirm=""
    if [[ -r /dev/tty ]]; then
      read -r -p "Kabul için EVET yazın: " confirm 2>/dev/null </dev/tty || true
    fi
    if [[ -z "$confirm" ]]; then
      read -r -p "Kabul için EVET yazın: " confirm || true
    fi
    [[ "$(printf '%s' "$confirm" | tr '[:lower:]' '[:upper:]')" == "EVET" ]] || fail "Şartlar kabul edilmedi."
    local attempt=1
    while (( attempt <= 4 )); do
      local code
      code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/terms/accept" \
        -H "X-API-Key: ${key}" -H "Authorization: Bearer ${key}" \
        -H "Content-Type: application/json" --data "{\"version\":${version}}")" || code="000"
      if [[ "$code" == "429" && "$attempt" -lt 4 ]]; then sleep 6; attempt=$(( attempt + 1 )); continue; fi
      [[ "$code" == "200" ]] || fail "terms/accept başarısız (HTTP $code)."
      break
    done
    ok "Kullanım şartları v${version} kabul edildi."
  else
    ok "Kullanım şartları zaten kabul edilmiş (v${version})."
  fi
}

do_diagnose() {
  require_v2
  printf '=== EVREN teşhisi (salt-okunur) ===\n'
  command -v opencode >/dev/null 2>&1 && ok "opencode: $(opencode --version 2>/dev/null || echo kurulu)" || warn "opencode PATH'te yok."
  [[ -f "$CONFIG_PATH" ]] && ok "config var: $CONFIG_PATH" || warn "config yok: $CONFIG_PATH"
  python3 - "$CONFIG_PATH" <<'PYEOF' || true
import sys, json, os, re
p = sys.argv[1]
if not os.path.isfile(p):
    print("[INFO] providers.evren: config yok")
    sys.exit(0)
raw = re.sub(r'(?m)^\s*//.*$', '', open(p, encoding="utf-8").read())
raw = re.sub(r'/\*[\s\S]*?\*/', '', raw)
raw = re.sub(r',\s*([}\]])', r'\1', raw)
try:
    cfg = json.loads(raw)
except Exception as e:
    print(f"[UYARI] config parse edilemedi: {e}")
    sys.exit(0)
ev = (cfg.get("providers") or {}).get("evren")
print(f"[{'OK' if ev else 'UYARI'}] providers.evren: {'var' if ev else 'yok'}")
if ev and "apiKey" in (ev.get("settings") or {}):
    print("[UYARI] config içinde apiKey alanı var — kuruluma aykırı, kaldırılmalı")
PYEOF
  if [[ -n "${EVREN_API_KEY:-}" ]]; then info "EVREN_API_KEY env: tanımlı (uzunluk ${#EVREN_API_KEY})"; fi
  if [[ -f "$KEY_FILE" ]]; then
    info ".evren-config: var ($(mask_key "$(read_saved_key 2>/dev/null || echo x)"))"
  else
    warn ".evren-config yok: $KEY_FILE"
  fi
  [[ -d "$PLUGIN_DIR" ]] && ok "plugin dizini var ($PLUGIN_DIR)" || warn "plugin kurulu değil."
  if key="$(read_saved_key 2>/dev/null || printf '%s' "${EVREN_API_KEY:-}")"; [[ -n "$key" ]]; then
    printf '[INFO] terms: %s\n' "$(api_get "/terms/status" "$key" 2>/dev/null || echo 'ulaşılamadı')"
    printf '[INFO] quota: %s\n' "$(api_get "/quota" "$key" 2>/dev/null || echo 'ulaşılamadı')"
  else
    warn "Anahtar bulunamadı; canlı kontroller atlandı."
  fi
}

do_set_key() {
  require_v2
  printf '=== EVREN anahtar güncelleme (config/plugin korunur) ===\n'
  local key
  key="$(prompt_key "Yeni EVREN API anahtarınız (evren_llm_...)")"
  export EVREN_API_KEY="$key"
  write_key_file "$key"
  terms_flow "$key"
  printf '\nKota: %s\n' "$(api_get "/quota" "$key")"
  info "Farklı bir hesapsa model listesi için --sync-models çalıştırın."
}

do_sync_models() {
  require_v2
  printf '=== EVREN model senkronu ===\n'
  local key
  key="$(read_saved_key 2>/dev/null || printf '%s' "${EVREN_API_KEY:-}")"
  [[ -n "$key" ]] || fail "Kayıtlı anahtar yok. Önce kurulumu çalıştırın."
  local map
  if raw="$(api_get "/models" "$key" 2>/dev/null)" && map="$(printf '%s' "$raw" | build_models_map 2>/dev/null)"; then
    ok "Model listesi API'den alındı."
  else
    warn "API'ye ulaşılamadı; gömülü liste kullanılacak."
    map="$(fallback_models_map)"
  fi
  backup_config
  merge_config "$map"
}

do_uninstall() {
  require_v2
  printf '=== EVREN kaldırma ===\n'
  backup_config
  if [[ -f "$CONFIG_PATH" ]]; then
    MODELS_MAP_JSON='{}' python3 - "$CONFIG_PATH" <<'PYEOF' || true
import sys, json, os, re
p = sys.argv[1]
raw = open(p, encoding="utf-8").read()
raw = re.sub(r'(?m)^\s*//.*$', '', raw)
raw = re.sub(r'/\*[\s\S]*?\*/', '', raw)
raw = re.sub(r',\s*([}\]])', r'\1', raw)
try:
    cfg = json.loads(raw)
except Exception:
    sys.exit(0)
for root in ("providers", "provider"):
    if isinstance(cfg.get(root), dict) and "evren" in cfg[root]:
        del cfg[root]["evren"]
        if not cfg[root]:
            del cfg[root]
for k in ("model", "small_model"):
    if isinstance(cfg.get(k), str) and cfg[k].startswith("evren/"):
        del cfg[k]
open(p, "w", encoding="utf-8").write(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print("[OK] providers.evren bloğu kaldırıldı.")
PYEOF
  fi
  rm -rf "$PLUGIN_DIR" && ok "Plugin dizini silindi." || true
  rm -f "$KEY_FILE" "$LEGACY_KEY_FILE" "$LEGACY_HOME_KEY" && ok "Anahtar dosyaları silindi." || true
  # bykemalh kalıntısı: RC dosyalarındaki kalıcı export satırları temizlenir.
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile" "${HOME}/.bash_profile"; do
    if [[ -f "$rc" ]] && grep -q 'EVREN_LLM_API_KEY\|EVREN_API_KEY' "$rc"; then
      tmp="$(mktemp)"; grep -v 'EVREN_LLM_API_KEY\|EVREN_API_KEY' "$rc" > "$tmp" || true
      cat "$tmp" > "$rc"; rm -f "$tmp"
      ok "Kalıcı env satırı temizlendi: $rc"
    fi
  done
  ok "Kaldırma tamamlandı."
}

do_install() {
  printf '=== EVREN LLM + OpenCode kurulumu ===\n'
  if ! command -v opencode >/dev/null 2>&1; then
    warn "opencode bulunamadı; kurulmaya çalışılıyor..."
    curl -fsSL https://opencode.ai/install | bash || fail "opencode kurulamadı (https://opencode.ai adresinden elle kurun)."
  fi
  require_v2

  local key
  key="$(prompt_key "EVREN API anahtarınız (evren_llm_...)")"
  export EVREN_API_KEY="$key"

  write_key_file "$key"
  terms_flow "$key"

  local verify status2
  verify="$(api_get "/terms/status" "$key")"
  status2="$(printf '%s' "$verify" | python3 -c 'import sys,json; print(str(json.load(sys.stdin).get("accepted", False)))')"
  [[ "$status2" == "True" ]] || fail "Şart kabulü doğrulanamadı."
  ok "Şart kabulü doğrulandı."

  local map raw
  if raw="$(api_get "/models" "$key")" && map="$(printf '%s' "$raw" | build_models_map)"; then
    ok "Model listesi API'den alındı."
  else
    warn "Model listesi alınamadı; gömülü liste kullanılacak."
    map="$(fallback_models_map)"
  fi
  backup_config
  merge_config "$map"
  install_plugin

  if command -v opencode >/dev/null 2>&1; then
    if opencode debug config 2>/dev/null | grep -q '"evren"'; then
      ok "Doğrulandı: opencode config içinde evren provider'ını görüyor."
    else
      warn "opencode config içinde evren görünmüyor."
    fi
    printf '\nKota: %s\n' "$(api_get "/quota" "$key")"
    info "opencode servisi yeniden başlatılıyor (plugin ve sidebar için)..."
    if opencode service restart >/dev/null 2>&1; then
      ok "opencode servisi yeniden başlatıldı."
    else
      warn "Otomatik restart başarısız oldu."
    fi
  fi
  printf '\nKurulum bitti.\n'
  printf 'Test: opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."\n'
  printf 'Servisi daha sonra elle yeniden başlatmak isterseniz: opencode service restart\n'
}

case "${1:-}" in
  --set-key) info "opencode-for-evren v${INSTALLER_VERSION}"; do_set_key ;;
  --sync-models|--update-models) info "opencode-for-evren v${INSTALLER_VERSION}"; do_sync_models ;;
  --uninstall) info "opencode-for-evren v${INSTALLER_VERSION}"; do_uninstall ;;
  --diagnose) info "opencode-for-evren v${INSTALLER_VERSION}"; do_diagnose ;;
  "") info "opencode-for-evren v${INSTALLER_VERSION}"; do_install ;;
  *) fail "Bilinmeyen parametre: $1 (--set-key | --sync-models | --uninstall | --diagnose)" ;;
esac
