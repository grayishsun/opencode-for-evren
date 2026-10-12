# opencode-for-evren

EVREN LLM'i ([evren.ssyz.org.tr](https://evren.ssyz.org.tr)) OpenCode'da (v2) kullanmak için
tek-tık kurulum + plugin paketi. macOS, Linux ve Windows 10/11 desteklenir.

> **Önemli:** Bu repo, `bykemalh/evren-llm-opencode` çalışmasındaki bilinen sorunları
> gideren sıfırdan yazımdır: çift başlık (`X-API-Key` + `Bearer`) desteği, 429 backoff,
> v2 provider şeması (`providers`, `package`, `env`), config'e **anahtar yazmama**,
> otomatik model senkronu ve sidebar'da CR bakiyesi.

## Hızlı kurulum

Anahtarınızı [evren.ssyz.org.tr/api-keys](https://evren.ssyz.org.tr/api-keys) adresinden alın
(`evren_llm_...` ile başlar).

**Linux / macOS:**

```bash
curl -fsSL https://raw.githubusercontent.com/grayishsun/opencode-for-evren/main/scripts/install.sh | bash
```

**Windows PowerShell** (normal kullanıcı, yönetici değil):

```powershell
irm "https://raw.githubusercontent.com/grayishsun/opencode-for-evren/main/scripts/install.ps1" | iex
```

**Windows CMD:**

```cmd
curl -fsSL "https://raw.githubusercontent.com/grayishsun/opencode-for-evren/main/scripts/install.ps1" -o "%TEMP%\evren-install.ps1" && powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\evren-install.ps1"
```

Kurulum sırasıyla şunları yapar:

1. Anahtarı gizli alır, biçimi doğrular, **yalnızca**
   `~/.config/opencode/.evren-config` dosyasına yazar (`chmod 600` / kullanıcı-özel ACL).
2. EVREN kullanım şartlarını gösterir (`/v1/terms/*`); daha önce kabul edildiyse atlar.
3. `/v1/models` üzerinden güncel sohbet modellerini çeker (`chat` / `vision_chat`;
   embedding/rerank/OCR/ses elenir), `limit` ve `capabilities.tools` değerlerini
   API'deki gerçek değerlerden yazar. API'ye ulaşılamazsa gömülü liste kullanılır (uyarıyla).
4. `opencode.jsonc` içindeki hiçbir ayarı silmeden `providers.evren` bloğunu v2 şemasında
   yazar. **Config'e anahtar yazılmaz** — ne değer olarak ne `{env:}` referansı olarak.
5. Plugin dosyalarını `~/.config/opencode/plugins/evren/` altına kurar.
6. `opencode debug config` ile provider'ın göründüğünü doğrular, güncel kotayı özetler.

Kurulumdan sonra TUI/IDE servisini yeniden başlatın (sidebar bakiyesi için):

```bash
opencode service restart
opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."
```

## Neler içerir

| Parça | Açıklama |
| --- | --- |
| `scripts/install.sh` | Linux/macOS kurulum, `--sync-models`, `--uninstall`, `--diagnose` |
| `scripts/install.ps1` | Windows kurulum (aynı bayraklar: `-SyncModels`, `-Uninstall`, `-Diagnose`) |
| `scripts/install.cmd` | CMD'den `install.ps1`'e ince yönlendirici |
| `src/index.ts` | Server plugin: provider kaydı, 10 dk'da bir model senkronu, 60 sn'de bir `/v1/quota` yoklaması, `X-Evren-*` yanıt başlığı yakalama, 429 retry backoff, `/evren` komutu, `evren_status` aracı |
| `src/tui.tsx` | TUI plugin: **sidebar footer'da kalan CR** + seviye, kota kötüleşince uyarı toast'ı |
| `src/rpc.ts` | Server↔TUI paylaşımlı RPC sözleşmesi (`status` + `updated` olayı) |
| `examples/opencode.jsonc` | Elle kurulum için en küçük v2 provider örneği |

Oturum içindeyken `/evren` yazmak kota + şart + model özetini gösterir.
`evren_status` aracı sayesinde modelin kendisi de kotayı okuyabilir.

## Güvenlik modeli

- API anahtarı `opencode.jsonc` / proje config'lerine **yazılmaz**.
- Tek kaynak: `~/.config/opencode/.evren-config` → `{"apiKey": "...", "updatedAt": "..."}`.
  Okuma sırası: `EVREN_API_KEY` env → `EVREN_LLM_API_KEY` env → `.evren-config` →
  legacy `.evren-key` → `~/.evren-config`.
- Kurulum, eski `.evren-key` dosyasını içe aktarıp siler; RC dosyalarına kalıcı
  `export` satırı **yazmaz** (önceki kurulumlardan kalanları `--uninstall` temizler).
- Teşhis/log çıktılarında anahtar **asla** yazdırılmaz; yalnızca `evren_llm_…XXXX`
  maskesi gösterilir. `opencode debug config` anahtarı `***` maskeler.
- `.gitignore`, `.evren-config` / `.evren-key` dosyalarını kapsar.
- ⚠️ Anahtarınızı bir yere yapıştırdıysanız (log, ekran görüntüsü, issue) panelden
  yenileyin.

## Komutlar

```bash
# Sadece model listesini tazele (anahtar sormaz, şart adımını atlar)
./scripts/install.sh --sync-models            # PS: .\install.ps1 -SyncModels

# Salt-okunur teşhis (canlı terms/quota dahil, anahtar yazdırmaz)
./scripts/install.sh --diagnose               # PS: .\install.ps1 -Diagnose

# Geri al: provider bloğu, plugin dizini, anahtar dosyaları, kalıcı env kalıntıları
./scripts/install.sh --uninstall              # PS: .\install.ps1 -Uninstall
```

## Desteklenen modeller

Liste kurulumda ve plugin tarafından otomatik çekilir; aşağıdaki tablo 2026-10-12
tarihli örnek görünümdür (`--sync-models` ile tazelenir):

| Model | Bağlam | Çıktı | Araç çağrısı |
| --- | --- | --- | --- |
| `evren/glm-5.3` (varsayılan) | 524288 | 16384 | evet |
| `evren/deepseek-v4.1-flash` (small_model) | 1048576 | 65536 | evet |
| `evren/deepseek-v4-flash` | 1048576 | 16384 | evet |
| `evren/qwen3.8-flash-next` | 262144 | 16384 | evet |
| `evren/gemma-4-31b` | 262144 | 16384 | evet |
| `evren/qwen3-vl-30b` | 262144 | 16384 | evet (görsel) |
| `evren/mimo-v2.6-pro` | 1048576 | 16384 | evet |
| `evren/auto` | 32768 | 16384 | hayır (sunucu yönlendirmesi) |

## API kapsamı

Doğrulanan uçlar (`EVREN LLM API 0.1.0` openapi): `/v1/chat/completions`,
`/v1/models`, `/v1/quota` (CR bakiyesi), `/v1/terms/status|text|accept`,
`/v1/responses`, `/v1/embeddings`, `/v1/rerank`, `/v1/ocr`,
`/v1/audio/transcriptions`, `/v1/systemone`. OpenCode sohbet akışı
`chat/completions` üzerinden yürür; kota bilgisi `/v1/quota` + `X-Evren-*`
yanıt başlıklarından beslenir. Hata gövdesindeki `error.evren` ayrıntıları
(kalan kota, alternatif model, kabul sürümü) plugin log/toast'larına taşınır.

## Sorun giderme

| Sorun | Çözüm |
| --- | --- |
| `429` / `5 saniye sonra tekrar deneyin` | Normal: gateway soğuma uygular. Plugin otomatik bekleyip dener; paralel oturum açmayın. |
| `terms ... accepted=true doğrulanamadı` | Kurulumu yeniden çalıştırın, şartları `EVET` ile onaylayın. |
| `FileSystem.readFile ... .evren-key (ENOENT)` | Eski kurulum artığı: yeni kurulum `.evren-config`'e taşır; `--diagnose` ile doğrulayın. |
| Config içinde `apiKey` alanı görünüyor | Bu kuruluma aykırı: `--uninstall` + yeniden kurun (değer config'e yazılmaz). |
| Sidebar'da bakiye görünmüyor | `opencode service restart`; `opencode plugin list` içinde evren geçmeli. |
| `opencode` yok | Kurulum dener (unix: `opencode.ai/install`, Windows: winget); olmazsa [opencode.ai](https://opencode.ai) adresinden elle kurun. |

## Geliştirme

```bash
npm install
npm run typecheck   # tsc --noEmit
```

Doğrulama durumu (v0.1.0): `bash -n`, PowerShell Parser, `tsc`, JSON parse,
canlı `/v1/models` eşleşmesi (8 model), sandbox merge (v1→v2 göçü + apiKey temizliği),
sandbox `--sync-models` (fallback) / `--uninstall` / `--diagnose` (canlı quota) —
tamamı geçti. Canlı sohbet duman testi kurulum sonrası tek komutla yapılır
(kredi harcar, bu yüzden CI'da koşmaz).

## Lisans

MIT — bkz. [LICENSE](LICENSE). EVREN API kullanımı EVREN Kullanım Şartları'na tabidir.

---

### English summary

One-click EVREN LLM setup + plugin for OpenCode v2 (macOS/Linux/Windows).
The installer writes your key **only** to `~/.config/opencode/.evren-config`
(never into `opencode.jsonc`), syncs chat models from `/v1/models`, handles the
terms gate, and installs a plugin that shows remaining CR in the sidebar footer,
exposes an `/evren` command and an `evren_status` tool, and backs off on 429s.
