# changelog

## v0.1.2 — 2026-10-12

- Kurulum scriptleri açılışta sürüm basar (`opencode-for-evren vX.Y.Z`);
  eski kopyayla çalıştırma karışıklığı önlenir.
- `Read-SavedKey` (ps1) legacy ham anahtar denetimi de gevşek biçime alındı.

## v0.1.1 — 2026-10-12

- Anahtar biçim kapısı esnetildi: `evren_llm_` öneki + en az 8 boşluksuz
  karakter yeterli; gerçek doğrulama canlı API çağrısıdır (401). Önceki katı
  regex (`[A-Za-z0-9_-]`), içinde `+/=.` gibi karakterler bulunan ya da
  tırnak/görünmez karakterle yapıştırılan geçerli anahtarları reddediyordu.
- Yapıştırma temizliği: baştaki/sondaki tırnaklar, sıfır-genişlikli
  karakterler (U+200B–U+200D) ve BOM ayıklanır; hata mesajı anahtar
  uzunluğunu gösterir (değer yazdırılmaz).

## v0.1.0 — 2026-10-12

İlk sürüm. `bykemalh/evren-llm-opencode` temel alınarak opencode **v2** için
sıfırdan yazıldı; bilinen kırılmalar giderildi.

### Eklenenler

- Tek-tık kurulum: `scripts/install.sh` (Linux/macOS), `scripts/install.ps1`
  (Windows), `scripts/install.cmd` (CMD yönlendirici).
- Bayraklar: `--sync-models` / `-SyncModels`, `--uninstall` / `-Uninstall`,
  `--diagnose` / `-Diagnose` (salt-okunur, anahtarı yazdırmaz).
- Server plugin (`src/index.ts`): v2 `provider.transform` ile `evren` kaydı,
  `/v1/models` yoklaması (10 dk), `/v1/quota` yoklaması (60 sn),
  `X-Evren-*` yanıt başlığı yakalama, 429 retry backoff, `/evren` komutu,
  `evren_status` aracı, RPC `status` + `updated` olayı.
- TUI plugin (`src/tui.tsx`): sidebar footer'da kalan CR + seviye, kötüleşmede
  uyarı toast'ı.
- Güvenlik: anahtar yalnızca `~/.config/opencode/.evren-config` (600/ACL);
  config'e anahtar yazılmaz; legacy `.evren-key` içe aktarılıp silinir; kalıcı
  RC/`setx` yazımı kaldırıldı, `--uninstall` kalıntıları temizler.
- `examples/opencode.jsonc`: en küçük v2 provider örneği.

### Düzeltilenler (önceki çalışmaya göre)

- Auth başlık ikiliği: her çağrıda `X-API-Key` + `Bearer` birlikte gönderilir
  (ikisi de `/v1/models` ile 200 doğrulandı).
- 429 soğuma: kurulumda ve plugin retry kancasında 6 sn backoff (4 deneme).
- v2 şema: `providers` + `package: @opencode/ai/providers/openai-compatible` +
  `env: [EVREN_API_KEY, EVREN_LLM_API_KEY]`; `settings.apiKey` config'de yok,
  kimlik plugin üzerinden çözülür.
- `deepseek-v4.1-flash` çıktı limiti 16384 → **65536** (canlı API değeri).
- `auto` modeli `tools: false` olarak işaretlendi (API `capabilities` değeri).
- Model yetenekleri/girdi türleri API `modalities` alanından alınır.
- `.evren-key` yokken config yeniden yükleme çökmesi (ENOENT): dosya referansı
  kalktı, eksik anahtar zarif hataya düşer.

### Doğrulama

`bash -n`, PowerShell Parser, `tsc --noEmit`, JSON parse, canlı `/v1/models`
eşleşmesi (8 seçilebilir model), sandbox merge (v1→v2 göçü, apiKey temizliği,
`other` provider korunumu), sandbox `--sync-models` (fallback),
`--uninstall`, `--diagnose` (canlı terms/quota) — tamamı geçti.
