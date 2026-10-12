import { readFileSync, existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { Model, Plugin, Provider } from "@opencode/plugin"
import { Evren } from "./rpc.js"

const BASE_URL = "https://evren-llmapi.ssyz.org.tr/v1"
const PROVIDER = "evren"
const MODELS_REFRESH_MS = 10 * 60_000
const QUOTA_REFRESH_MS = 60_000
const TIMEOUT_MS = 15_000
const RETRY_DELAY_MS = 6_000
const MAX_ATTEMPTS = 4

// Anahtar ASLA loglanmaz, snapshot'a konmaz, config'e yazılmaz.
// Çözüm sırası: process env -> .evren-config -> legacy .evren-key.
function resolveKey(): string {
  const fromEnv = process.env.EVREN_API_KEY ?? process.env.EVREN_LLM_API_KEY ?? ""
  if (fromEnv.trim()) return fromEnv.trim()

  const configDir = join(homedir(), ".config", "opencode")
  const candidates = [
    join(configDir, ".evren-config"),
    join(configDir, ".evren-key"),
    join(homedir(), ".evren-config"),
  ]
  for (const path of candidates) {
    try {
      if (!existsSync(path)) continue
      const raw = readFileSync(path, "utf-8").trim()
      if (!raw) continue
      if (raw.startsWith("{")) {
        const parsed = JSON.parse(raw) as { apiKey?: string; key?: string }
        const key = (parsed.apiKey ?? parsed.key ?? "").trim()
        if (key) return key
      } else if (/^evren_llm_[A-Za-z0-9_-]+$/.test(raw)) {
        return raw
      }
    } catch {
      // Okunamayan aday atlanır, sıradaki denenir.
    }
  }
  return ""
}

function headers(key: string): Record<string, string> {
  // Gateway iki şemayı da kabul ediyor (doğrulandı: /v1/models her ikisiyle 200).
  // İkisini birlikte göndermek Bearer/X-API-Key ayrımını ortadan kaldırır.
  return { "X-API-Key": key, Authorization: `Bearer ${key}` }
}

async function api<T>(path: string, key: string): Promise<T> {
  if (!key) throw new Error("EVREN anahtarı bulunamadı (.evren-config yok, env boş)")
  let lastError = ""
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    const response = await fetch(`${BASE_URL}${path}`, {
      headers: headers(key),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    })
    if (response.status === 429 && attempt < MAX_ATTEMPTS) {
      await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS))
      continue
    }
    if (!response.ok) {
      const body = await response.text().catch(() => "")
      lastError = `${path} -> HTTP ${response.status}${body ? `: ${body.slice(0, 200)}` : ""}`
      throw new Error(lastError)
    }
    return (await response.json()) as T
  }
  throw new Error(lastError || `${path} -> rate limit aşılamadı`)
}

type RawModel = {
  id: string
  task?: string
  context_length?: number | null
  default_max_output_tokens?: number | null
  modalities?: string[] | null
  capabilities?: { tools?: boolean } | null
  pricing?: {
    prompt_token_price?: number | null
    completion_token_price?: number | null
    currency?: string | null
    free_until?: string | null
  } | null
}

// API erişilemezse kurulum ve plugin bu listeyle devam eder.
// Değerler 2026-10-12 /v1/models probundan alınmıştır.
const FALLBACK: RawModel[] = [
  { id: "glm-5.3", task: "chat", context_length: 524288, default_max_output_tokens: 16384, modalities: ["text"], capabilities: { tools: true } },
  { id: "deepseek-v4.1-flash", task: "chat", context_length: 1048576, default_max_output_tokens: 65536, modalities: ["text", "image"], capabilities: { tools: true } },
  { id: "deepseek-v4-flash", task: "chat", context_length: 1048576, default_max_output_tokens: 16384, modalities: ["text"], capabilities: { tools: true } },
  { id: "qwen3.8-flash-next", task: "chat", context_length: 262144, default_max_output_tokens: 16384, modalities: ["text", "image"], capabilities: { tools: true } },
  { id: "gemma-4-31b", task: "chat", context_length: 262144, default_max_output_tokens: 16384, modalities: ["text", "image"], capabilities: { tools: true } },
  { id: "qwen3-vl-30b", task: "vision_chat", context_length: 262144, default_max_output_tokens: 16384, modalities: ["text", "image"], capabilities: { tools: true } },
  { id: "mimo-v2.6-pro", task: "chat", context_length: 1048576, default_max_output_tokens: 16384, modalities: ["text", "image"], capabilities: { tools: true } },
  { id: "auto", task: "chat", context_length: 32768, default_max_output_tokens: 16384, modalities: ["text"], capabilities: { tools: false } },
]

function isSelectable(task: string | undefined) {
  return task === "chat" || task === "vision_chat"
}

function toModelInfo(raw: RawModel) {
  const base = Model.Info.default(Provider.ID.make(PROVIDER), Model.ID.make(raw.id))
  const context = raw.context_length ?? 200_000
  const output = raw.default_max_output_tokens ?? Math.min(8_192, context)
  const modalities = (raw.modalities ?? ["text"]).filter((m) => m === "text" || m === "image")

  // Model.Info.default daraltılmış bir şablon döner; doğrudan mutasyon yerine
  // yayılımla yeni nesne kurulur (Model.Info arayüzüne atanabilir).
  return {
    ...base,
    name: raw.id,
    enabled: isSelectable(raw.task),
    limit: { ...base.limit, context, output },
    capabilities: {
      ...base.capabilities,
      tools: raw.capabilities?.tools === true,
      input: modalities.length > 0 ? modalities : ["text"],
      output: ["text"],
    },
  }
}

function toInventoryEntry(raw: RawModel) {
  return {
    id: raw.id,
    task: raw.task ?? "chat",
    context: raw.context_length ?? null,
    output: raw.default_max_output_tokens ?? null,
    tools: raw.capabilities?.tools === true,
    vision: (raw.modalities ?? []).includes("image"),
    selectable: isSelectable(raw.task),
    priceIn: raw.pricing?.prompt_token_price ?? null,
    priceOut: raw.pricing?.completion_token_price ?? null,
    currency: raw.pricing?.currency ?? "CR",
    freeUntil: raw.pricing?.free_until ?? null,
  }
}

type Snapshot = {
  connected: boolean
  syncedAt: string
  baseUrl: string
  quota: Record<string, unknown> | null
  terms: Record<string, unknown> | null
  last: Record<string, unknown> | null
  models: Array<Record<string, unknown>>
  error: string | null
}

function quotaSummary(quota: Record<string, unknown> | null): string {
  if (!quota) return "kota bilgisi yok"
  const remaining = quota["remaining_cr"] ?? "?"
  const held = quota["held_cr"] ?? "?"
  const level = quota["level"] ?? "?"
  const daily = quota["daily_remaining_tokens"] ?? "?"
  return `CR kalan=${remaining} hold=${held} seviye=${level} günlük-kalan-token=${daily}`
}

export default Plugin.define({
  id: "evren",
  async setup(ctx) {
    const key = resolveKey()
    let quota: Record<string, unknown> | null = null
    let terms: Record<string, unknown> | null = null
    let last: Record<string, unknown> | null = null
    let inventory: RawModel[] = []
    let error: string | null = key ? null : "EVREN anahtarı bulunamadı"

    const snapshot = (): Snapshot => ({
      connected: quota !== null,
      syncedAt: new Date().toISOString(),
      baseUrl: BASE_URL,
      quota,
      terms,
      last,
      models: inventory.map(toInventoryEntry),
      error,
    })

    const rpc = await ctx.rpc.register(Evren, {
      status: async () => snapshot(),
    })
    const publish = () => {
      rpc.events.emit("updated", { at: new Date().toISOString() }).catch(() => {})
    }

    // --- model envanteri: /v1/models tek doğruluk kaynağıdır ---
    const loadModels = async () => {
      const data = await api<{ data?: RawModel[] }>("/models", key)
      const list = Array.isArray(data?.data) ? data.data : []
      const selectable = list.filter((m) => m.id && isSelectable(m.task))
      if (selectable.length === 0) throw new Error("API seçilebilir sohbet modeli döndürmedi")
      inventory = list
    }

    try {
      if (key) await loadModels()
      else inventory = [...FALLBACK]
    } catch (cause) {
      error = cause instanceof Error ? cause.message : String(cause)
      inventory = [...FALLBACK]
      console.error("[evren] model listesi alınamadı, gömülü liste kullanılıyor:", error)
    }

    const providerID = Provider.ID.make(PROVIDER)
    const info = {
      ...Provider.Info.empty(providerID),
      name: "EVREN LLM",
      activation: "enabled" as const,
      package: "@opencode/ai/providers/openai-compatible",
      settings: key ? { baseURL: BASE_URL, apiKey: key } : { baseURL: BASE_URL },
    }
    const source = { models: inventory.map(toModelInfo) }
    const providerRegistration = await ctx.provider.transform((editor) => {
      if (editor.get(PROVIDER)) editor.models.set(PROVIDER, source.models)
      else editor.add({ info, models: source.models })
    })

    // --- kota + şartlar ---
    const refresh = async () => {
      if (!key) return
      try {
        quota = await api<Record<string, unknown>>("/quota", key)
        terms = await api<Record<string, unknown>>("/terms/status", key)
        error = null
        publish()
      } catch (cause) {
        error = cause instanceof Error ? cause.message : String(cause)
      }
    }
    await refresh()
    const quotaTimer = setInterval(() => void refresh(), QUOTA_REFRESH_MS)
    const modelsTimer = setInterval(() => {
      void (async () => {
        if (!key) return
        try {
          await loadModels()
          source.models = inventory.map(toModelInfo)
          error = null
          await ctx.provider.reload()
          publish()
        } catch (cause) {
          error = cause instanceof Error ? cause.message : String(cause)
          console.error("[evren] model yenilemesi başarısız:", error)
        }
      })()
    }, MODELS_REFRESH_MS)

    // --- yanıt başlıkları: akışı tüketmeden kredi/yönlendirme bilgisi ---
    const headerHook = await ctx.session.hook(
      "http.response",
      (event) => {
        const evt = event as unknown as {
          kind?: string
          sessionID?: string
          model?: { modelID?: string; id?: string }
          response?: { headers?: { get?: (name: string) => string | null } }
        }
        const get = (name: string) => evt.response?.headers?.get?.(name) ?? undefined
        last = {
          at: new Date().toISOString(),
          kind: evt.kind ?? null,
          sessionID: evt.sessionID ?? null,
          model: evt.model?.modelID ?? evt.model?.id ?? null,
          routedModel: get("x-evren-routed-model") ?? null,
          routingReason: get("x-evren-routing-reason") ?? null,
          creditsHeld: get("x-evren-credits-held") ?? null,
          creditsRemaining: get("x-evren-credits-remaining") ?? null,
          rateLimitRemainingTokens: get("x-ratelimit-remaining-tokens") ?? null,
          dailyRemainingTokens: get("x-evren-daily-remaining-tokens") ?? null,
        }
        publish()
      },
      { providerID: PROVIDER },
    )

    // --- 429 backoff: EVREN ~5sn soğuma uygular, ilk denemelerde bekle ---
    const retryHook = await ctx.session.hook("retry", (event) => {
      const evt = event as unknown as {
        attempt?: number
        decision?: { retry: boolean; delay?: number }
        error?: { status?: number; message?: string }
        model?: { providerID?: string }
        providerID?: string
      }
      const mine =
        evt.model?.providerID === PROVIDER ||
        evt.providerID === PROVIDER ||
        /evren/i.test(evt.error?.message ?? "")
      if (!mine) return
      if (evt.error?.status === 429 && (evt.attempt ?? 1) < MAX_ATTEMPTS) {
        evt.decision = { retry: true, delay: RETRY_DELAY_MS }
      }
    })

    // --- /evren komutu: oturum içinde kota + şart + model özeti ---
    const commandRegistration = await ctx.command.transform((editor) => {
      editor.add({
        name: "evren",
        description: "EVREN kotası, kullanım şartları ve model listesini gösterir",
        execute: async ({ sessionID, prompt, delivery }) => {
          const snap = snapshot()
          const lines = [
            `EVREN durumu (${snap.syncedAt})`,
            `Kota: ${quotaSummary(snap.quota)}`,
            `Şartlar: ${snap.terms ? `v${String(snap.terms["current_version"] ?? "?")} accepted=${String(snap.terms["accepted"] ?? "?")}` : "bilinmiyor"}`,
            `Modeller: ${snap.models.filter((m) => m["selectable"]).map((m) => String(m["id"])) .join(", ") || "yok"}`,
          ]
          if (snap.error) lines.push(`Uyarı: ${snap.error}`)
          await ctx.session.prompt({ ...prompt, sessionID, text: lines.join("\n"), delivery })
        },
      })
    })

    // --- evren_status aracı: modelin kendi kendine kotayı okuması için ---
    const toolRegistration = await ctx.tool.transform((editor) => {
      editor.add({
        name: "evren_status",
        description: "EVREN API kotasını (kalan CR), kullanım şartı durumunu ve model listesini döndürür. Ağ anahtarı gerektirmez.",
        input: {
          type: "object",
          properties: {},
          required: [],
          additionalProperties: false,
        },
        execute: async (_input: unknown) => {
          const snap = snapshot()
          return {
            content: JSON.stringify(
              {
                connected: snap.connected,
                syncedAt: snap.syncedAt,
                quota: snap.quota,
                terms: snap.terms,
                lastResponse: snap.last,
                models: snap.models,
                error: snap.error,
              },
              null,
              2,
            ),
          }
        },
      })
    })

    console.error(
      key
        ? `[evren] ${source.models.length} model yüklendi, kota izleniyor`
        : "[evren] anahtar yok: .evren-config yazılmadan provider pasif kalır",
    )

    return () => {
      clearInterval(quotaTimer)
      clearInterval(modelsTimer)
      void headerHook.dispose()
      void retryHook.dispose()
      void commandRegistration.dispose()
      void toolRegistration.dispose()
      void providerRegistration.dispose()
      void rpc.dispose()
    }
  },
})
