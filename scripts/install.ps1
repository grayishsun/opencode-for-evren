<#
.SYNOPSIS
    EVREN LLM + OpenCode kurulumu (Windows, opencode v2 uyumlu).
.DESCRIPTION
    Anahtar opencode.jsonc'ye YAZILMAZ. Tek kaynak:
    %USERPROFILE%\.config\opencode\.evren-config (JSON, kullanıcı-özel ACL).
    Provider bloğu v2 şemasındadır, kimlik plugin üzerinden çözülür.
.EXAMPLE
    .\install.ps1
    .\install.ps1 -SyncModels
    .\install.ps1 -Uninstall
    .\install.ps1 -Diagnose
#>
[CmdletBinding()]
param(
    [switch]$SyncModels,
    [switch]$Uninstall,
    [switch]$Diagnose
)

$ErrorActionPreference = "Stop"

$BaseUrl    = "https://evren-llmapi.ssyz.org.tr/v1"
$RepoRaw    = "https://raw.githubusercontent.com/grayishsun/opencode-for-evren/main"
$ConfigDir  = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".config\opencode"
$ConfigPath = Join-Path $ConfigDir "opencode.jsonc"
$KeyFile    = Join-Path $ConfigDir ".evren-config"
$LegacyKey  = Join-Path $ConfigDir ".evren-key"
$LegacyHome = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".evren-config"
$PluginDir  = Join-Path $ConfigDir "plugins\evren"
$PluginFiles = @("package.json", "src/index.ts", "src/rpc.ts", "src/tui.tsx")
$InstallerVersion = "0.1.4"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Fail([string]$Message) { Write-Host ""; Write-Host "HATA: $Message" -ForegroundColor Red; exit 1 }
function Ok([string]$Message)   { Write-Host "[OK] $Message" -ForegroundColor Green }
function Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor DarkYellow }
function Warn([string]$Message) { Write-Host "[UYARI] $Message" -ForegroundColor Yellow }

function Get-MaskedKey([string]$Key) {
    if ($Key.Length -gt 8) { return "evren_llm_…" + $Key.Substring($Key.Length - 4) }
    return "(geçersiz)"
}

function Invoke-EvrenApi {
    param([string]$Path, [string]$Key, [string]$Method = "Get", $Body = $null)
    $headers = @{ "X-API-Key" = $Key; Authorization = "Bearer $Key" }
    $attempt = 1
    while ($attempt -le 4) {
        try {
            $params = @{ Method = $Method; Uri = "$BaseUrl$Path"; Headers = $headers }
            if ($Body) { $params.ContentType = "application/json"; $params.Body = $Body }
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            if ($status -eq 429 -and $attempt -lt 4) { Start-Sleep -Seconds 6; $attempt++; continue }
            throw
        }
    }
}

function Read-SavedKey {
    foreach ($p in @($KeyFile, $LegacyKey, $LegacyHome)) {
        if (-not (Test-Path $p)) { continue }
        try {
            $raw = (Get-Content $p -Raw -Encoding UTF8).Trim()
            if (-not $raw) { continue }
            if ($raw.StartsWith("{")) {
                $data = $raw | ConvertFrom-Json
                $k = "$($data.apiKey)$($data.key)".Trim()
                if ($k) { return $k }
            }
            elseif ($raw -match '^evren_llm_\S{8,}$') { return $raw }
        } catch {}
    }
    return $null
}

function Write-KeyFile([string]$Key) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $payload = @{ apiKey = $Key; updatedAt = [DateTime]::UtcNow.ToString("o") } | ConvertTo-Json
    # Not: Set-Content -Encoding UTF8NoBOM yalnız PS7+; 5.1 uyumluluğu için .NET yazımı (BOM'suz).
    [System.IO.File]::WriteAllText($KeyFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    try {
        & icacls $KeyFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    } catch { Warn "Dosya ACL sıkılaştırılamadı; dosya yine de yazıldı: $KeyFile" }
    Remove-Item $LegacyKey -Force -ErrorAction SilentlyContinue
    Ok "Anahtar yazıldı: $KeyFile"
}

function Backup-Config {
    if (Test-Path $ConfigPath) {
        $bak = "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $ConfigPath $bak
        Info "Config yedeklendi: $bak"
    }
}

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { return [PSCustomObject]@{} }
    $raw = Get-Content $ConfigPath -Raw -Encoding UTF8
    $stripped = $raw -replace '(?m)^\s*//.*$', '' -replace '/\*[\s\S]*?\*/', '' -replace ',\s*([}\]])', '$1'
    try { return ($stripped | ConvertFrom-Json) }
    catch { Warn "Config parse edilemedi; sıfırdan kurulacak (eski dosya yedeklendi)."; return [PSCustomObject]@{} }
}

function Write-Config([PSCustomObject]$Cfg) {
    [System.IO.File]::WriteAllText($ConfigPath, ($Cfg | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-ModelsMap($Payload) {
    $map = [PSCustomObject]@{}
    foreach ($m in $Payload.data) {
        if (-not $m -or -not $m.id) { continue }
        $task = if ($m.task) { $m.task } else { 'chat' }
        if ($task -notin @('chat', 'vision_chat')) { continue }
        $ctx = if ($m.context_length) { [int]$m.context_length } else { 200000 }
        $out = if ($m.default_max_output_tokens) { [int]$m.default_max_output_tokens } else { [Math]::Min(8192, $ctx) }
        $mods = @(@($m.modalities) | Where-Object { $_ -in @('text', 'image') })
        if ($mods.Count -eq 0) { $mods = @('text') }
        $tools = $false
        try { $tools = ($m.capabilities.tools -eq $true) } catch {}
        $map | Add-Member -NotePropertyName $m.id -NotePropertyValue (
            [PSCustomObject]@{ name = $m.id;
                capabilities = [PSCustomObject]@{ tools = $tools; input = $mods; output = @('text') };
                limit = [PSCustomObject]@{ context = $ctx; output = $out } }) -Force
    }
    if (($map.PSObject.Properties | Measure-Object).Count -eq 0) { throw "API seçilebilir sohbet modeli döndürmedi." }
    return $map
}

function Get-FallbackMap {
    $rows = @(
        @("glm-5.3", 524288, 16384, @("text"), $true),
        @("deepseek-v4.1-flash", 1048576, 65536, @("text", "image"), $true),
        @("deepseek-v4-flash", 1048576, 16384, @("text"), $true),
        @("qwen3.8-flash-next", 262144, 16384, @("text", "image"), $true),
        @("gemma-4-31b", 262144, 16384, @("text", "image"), $true),
        @("qwen3-vl-30b", 262144, 16384, @("text", "image"), $true),
        @("mimo-v2.6-pro", 1048576, 16384, @("text", "image"), $true),
        @("auto", 32768, 16384, @("text"), $false)
    )
    $map = [PSCustomObject]@{}
    foreach ($r in $rows) {
        $map | Add-Member -NotePropertyName $r[0] -NotePropertyValue (
            [PSCustomObject]@{ name = $r[0];
                capabilities = [PSCustomObject]@{ tools = $r[4]; input = $r[3]; output = @('text') };
                limit = [PSCustomObject]@{ context = $r[1]; output = $r[2] } }) -Force
    }
    return $map
}

function Merge-EvrenConfig($ModelsMap) {
    $cfg = Read-Config
    if ($cfg.provider -and $cfg.provider.PSObject.Properties["evren"]) {
        $cfg.provider.PSObject.Properties.Remove("evren")
        if (($cfg.provider.PSObject.Properties | Measure-Object).Count -eq 0) {
            $cfg.PSObject.Properties.Remove("provider")
        }
    }
    if (-not $cfg.PSObject.Properties['$schema']) {
        $cfg | Add-Member -NotePropertyName '$schema' -NotePropertyValue "https://opencode.ai/config.json" -Force
    }
    if (-not $cfg.PSObject.Properties["providers"]) {
        $cfg | Add-Member -NotePropertyName "providers" -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $evren = [PSCustomObject]@{
        name = "EVREN LLM"
        env = @("EVREN_API_KEY", "EVREN_LLM_API_KEY")
        package = "@opencode/ai/providers/openai-compatible"
        settings = [PSCustomObject]@{ baseURL = "https://evren-llmapi.ssyz.org.tr/v1" }
        models = $ModelsMap
    }
    $cfg.providers | Add-Member -NotePropertyName "evren" -NotePropertyValue $evren -Force
    $ids = @($ModelsMap.PSObject.Properties.Name)
    $needModel = (-not $cfg.PSObject.Properties["model"]) -or (($cfg.model -like "evren/*") -and ($ids -notcontains ($cfg.model -replace '^evren/', '')))
    if ($needModel) {
        if ($ids -contains "glm-5.3") { $d = "evren/glm-5.3" }
        elseif ($ids -contains "auto") { $d = "evren/auto" }
        else { $d = "evren/$($ids[0])" }
        $cfg | Add-Member -NotePropertyName "model" -NotePropertyValue $d -Force
    }
    $needSmall = (-not $cfg.PSObject.Properties["small_model"]) -or (($cfg.small_model -like "evren/*") -and ($ids -notcontains ($cfg.small_model -replace '^evren/', '')))
    if ($needSmall) {
        if ($ids -contains "deepseek-v4.1-flash") { $s = "evren/deepseek-v4.1-flash" }
        else { $s = "evren/" + (($ModelsMap.PSObject.Properties | Sort-Object { $_.Value.limit.context } | Select-Object -First 1).Name) }
        $cfg | Add-Member -NotePropertyName "small_model" -NotePropertyValue $s -Force
    }
    Write-Config -Cfg $cfg
    Ok "opencode.jsonc güncellendi (apiKey yazılmadı)."
}

function Install-Plugin {
    New-Item -ItemType Directory -Force -Path (Join-Path $PluginDir "src") | Out-Null
    $local = Join-Path $ScriptRoot "src"
    if (Test-Path (Join-Path $local "index.ts")) {
        Copy-Item (Join-Path $ScriptRoot "package.json") (Join-Path $PluginDir "package.json") -Force
        Copy-Item (Join-Path $local "index.ts") (Join-Path $PluginDir "src\index.ts") -Force
        Copy-Item (Join-Path $local "rpc.ts") (Join-Path $PluginDir "src\rpc.ts") -Force
        Copy-Item (Join-Path $local "tui.tsx") (Join-Path $PluginDir "src\tui.tsx") -Force
    } else {
        foreach ($f in @("package.json", "src/index.ts", "src/rpc.ts", "src/tui.tsx")) {
            $dest = Join-Path $PluginDir $f
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            Invoke-WebRequest -Uri "$RepoRaw/$f" -OutFile $dest
        }
    }
    # Eski düzende kalan kök dosyalar (index.ts/rpc.ts) yeni paketi gölgelerdi; temizlenir.
    foreach ($stale in @("index.ts", "index.js", "rpc.ts", "tui.ts", "tui.tsx")) {
        $p = Join-Path $PluginDir $stale
        if (Test-Path $p) { Remove-Item $p -Force }
    }
    Ok "Plugin kuruldu: $PluginDir"
}

function Invoke-TermsFlow([string]$Key) {
    $status = Invoke-EvrenApi -Path "/terms/status" -Key $Key
    $version = $status.current_version
    if (-not $version) { Fail "terms/status okunamadı." }
    if (-not $status.accepted) {
        $terms = Invoke-EvrenApi -Path "/terms/text" -Key $Key
        Write-Host ""
        Write-Host "=== EVREN Kullanım Şartları (v$version) ===" -ForegroundColor Yellow
        Write-Host $terms.content
        Write-Host ""
        $confirm = Read-Host "Kabul için EVET yazın"
        if ($confirm.Trim().ToUpperInvariant() -ne "EVET") { Fail "Şartlar kabul edilmedi." }
        $body = (@{ version = [int]$version } | ConvertTo-Json -Compress)
        Invoke-EvrenApi -Path "/terms/accept" -Key $Key -Method "Post" -Body $body | Out-Null
        Ok "Kullanım şartları v$version kabul edildi."
    } else {
        Ok "Kullanım şartları zaten kabul edilmiş (v$version)."
    }
}

function Invoke-Diagnose {
    Write-Host "=== EVREN teşhisi (salt-okunur) ===" -ForegroundColor Cyan
    if (Get-Command opencode -ErrorAction SilentlyContinue) { Ok "opencode kurulu." }
    else { Warn "opencode PATH'te yok." }
    if (Test-Path $ConfigPath) {
        $cfg = Read-Config
        if ($cfg.providers -and $cfg.providers.PSObject.Properties["evren"]) {
            Ok "providers.evren config içinde var."
            if ($cfg.providers.evren.settings.PSObject.Properties["apiKey"]) {
                Warn "config içinde apiKey alanı var — kuruluma aykırı, kaldırılmalı."
            }
        } else { Warn "providers.evren config içinde yok." }
    } else { Warn "config yok: $ConfigPath" }
    if ($env:EVREN_API_KEY) { Info "EVREN_API_KEY env tanımlı (uzunluk $($env:EVREN_API_KEY.Length))." }
    $saved = Read-SavedKey
    if ($saved) { Info ".evren-config: var ($(Get-MaskedKey $saved))." }
    else { Warn ".evren-config yok: $KeyFile" }
    if (Test-Path $PluginDir) { Ok "plugin dizini var." } else { Warn "plugin kurulu değil." }
    $live = if ($saved) { $saved } else { $env:EVREN_API_KEY }
    if ($live) {
        try { Info "terms: $(Invoke-EvrenApi -Path '/terms/status' -Key $live | ConvertTo-Json -Compress)" } catch { Warn "terms/status ulaşılamadı." }
        try { Info "quota: $(Invoke-EvrenApi -Path '/quota' -Key $live | ConvertTo-Json -Compress)" } catch { Warn "quota ulaşılamadı." }
    } else { Warn "Anahtar bulunamadı; canlı kontroller atlandı." }
}

function Invoke-SyncModels {
    Write-Host "=== EVREN model senkronu ===" -ForegroundColor Cyan
    $key = Read-SavedKey
    if (-not $key -and $env:EVREN_API_KEY) { $key = $env:EVREN_API_KEY }
    if (-not $key) { Fail "Kayıtlı anahtar yok. Önce kurulumu çalıştırın." }
    try {
        $map = ConvertTo-ModelsMap (Invoke-EvrenApi -Path "/models" -Key $key)
        Ok "Model listesi API'den alındı."
    } catch {
        Warn "API'ye ulaşılamadı ($($_.Exception.Message)); gömülü liste kullanılacak."
        $map = Get-FallbackMap
    }
    Backup-Config
    Merge-EvrenConfig -ModelsMap $map
}

function Invoke-Uninstall {
    Write-Host "=== EVREN kaldırma ===" -ForegroundColor Cyan
    Backup-Config
    if (Test-Path $ConfigPath) {
        $cfg = Read-Config
        foreach ($root in @("providers", "provider")) {
            if ($cfg.PSObject.Properties[$root] -and $cfg.$root.PSObject.Properties["evren"]) {
                $cfg.$root.PSObject.Properties.Remove("evren")
                if (($cfg.$root.PSObject.Properties | Measure-Object).Count -eq 0) {
                    $cfg.PSObject.Properties.Remove($root)
                }
            }
        }
        foreach ($k in @("model", "small_model")) {
            if ($cfg.PSObject.Properties[$k] -and ($cfg.$k -like "evren/*")) {
                $cfg.PSObject.Properties.Remove($k)
            }
        }
        Write-Config -Cfg $cfg
        Ok "providers.evren bloğu kaldırıldı."
    }
    if (Test-Path $PluginDir) { Remove-Item $PluginDir -Recurse -Force; Ok "Plugin dizini silindi." }
    foreach ($p in @($KeyFile, $LegacyKey, $LegacyHome)) {
        if (Test-Path $p) { Remove-Item $p -Force; Ok "Silindi: $p" }
    }
    foreach ($v in @("EVREN_API_KEY", "EVREN_LLM_API_KEY")) {
        if ([Environment]::GetEnvironmentVariable($v, "User")) {
            [Environment]::SetEnvironmentVariable($v, $null, "User")
            Remove-Item "Env:$v" -ErrorAction SilentlyContinue
            Ok "Kalıcı env temizlendi: $v"
        }
    }
    Ok "Kaldırma tamamlandı."
}

function Invoke-Install {
    Write-Host "=== EVREN LLM + OpenCode kurulumu ===" -ForegroundColor Cyan
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
        Warn "opencode bulunamadı; kurulmaya çalışılıyor..."
        try {
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                winget install -e --id anomalyco.opencode
            } else {
                irm "https://opencode.ai/install.ps1" | iex
            }
        } catch { Fail "opencode kurulamadı (https://opencode.ai adresinden elle kurun)." }
    }

    $secure = Read-Host "EVREN API anahtarınız (evren_llm_...)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    # Yapıştırma artıkları: kırp, tırnakları ve görünmez karakterleri at.
    $key = $key.Trim().Trim('"').Trim("'").Trim() -replace "[\u200B-\u200D\uFEFF]", ""
    # Biçim kapısı bilerek gevşek: gerçek doğrulama canlı API çağrısıdır (401).
    if ($key -notmatch '^evren_llm_\S{8,}$') {
        Fail "Anahtar biçimi tanınmadı (uzunluk $($key.Length)). Tırnaksız, 'evren_llm_' ile başlayan anahtarı panelden yeniden kopyalayın."
    }

    Write-KeyFile -Key $key
    Invoke-TermsFlow -Key $key

    $verify = Invoke-EvrenApi -Path "/terms/status" -Key $key
    if (-not $verify.accepted) { Fail "Şart kabulü doğrulanamadı." }
    Ok "Şart kabulü doğrulandı."

    try {
        $map = ConvertTo-ModelsMap (Invoke-EvrenApi -Path "/models" -Key $key)
        Ok "Model listesi API'den alındı."
    } catch {
        Warn "Model listesi alınamadı; gömülü liste kullanılacak."
        $map = Get-FallbackMap
    }
    Backup-Config
    Merge-EvrenConfig -ModelsMap $map
    Install-Plugin

    $dbg = opencode debug config 2>$null | Out-String
    if ($dbg -match '"evren"') { Ok "Doğrulandı: opencode config içinde evren provider'ını görüyor." }
    else { Warn "evren config içinde görünmüyor; servisin yeniden başlaması gerekebilir." }
    try { Info "quota: $(Invoke-EvrenApi -Path '/quota' -Key $key | ConvertTo-Json -Compress)" } catch {}
    Write-Host ""
    Write-Host "Kurulum bitti. Sidebar bakiye için TUI/IDE servisini yeniden başlatın." -ForegroundColor DarkGray
    Write-Host 'Test: opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."'
}

if ($Diagnose) { Write-Host "opencode-for-evren v$InstallerVersion" -ForegroundColor DarkGray; Invoke-Diagnose; exit 0 }
if ($SyncModels) { Write-Host "opencode-for-evren v$InstallerVersion" -ForegroundColor DarkGray; Invoke-SyncModels; exit 0 }
if ($Uninstall) { Write-Host "opencode-for-evren v$InstallerVersion" -ForegroundColor DarkGray; Invoke-Uninstall; exit 0 }
Write-Host "opencode-for-evren v$InstallerVersion" -ForegroundColor DarkGray
Invoke-Install
