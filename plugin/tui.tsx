import type {} from "@opentui/solid"
import { Plugin } from "@opencode/plugin/tui"
import { Evren } from "./rpc.js"

type QuotaView = {
  remaining: string
  held: string
  level: string
  daily: string
}

const EMPTY: QuotaView = { remaining: "?", held: "?", level: "?", daily: "?" }

function fmtDaily(v: string): string {
  const n = Number(v)
  if (!Number.isFinite(n)) return v
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}B`
  return String(n)
}

function viewOf(status: any): { quota: QuotaView; connected: boolean; error: string | null } {
  const quota = (status?.quota ?? null) as Record<string, unknown> | null
  if (!quota) return { quota: EMPTY, connected: false, error: (status?.error as string | null) ?? null }
  const str = (v: unknown) => (v === null || v === undefined ? "?" : String(v))
  return {
    quota: {
      remaining: str(quota["remaining_cr"]),
      held: str(quota["held_cr"]),
      level: str(quota["level"]),
      daily: str(quota["daily_remaining_tokens"]),
    },
    connected: true,
    error: null,
  }
}

export default Plugin.define({
  id: "evren-tui",
  async setup(context) {
    const evren = context.client.rpc(Evren)
    const [state, updateState] = context.storage.store("evren", {
      initial: { quota: EMPTY, connected: false, error: null as string | null },
    })

    let lastLevel = ""
    const refresh = async () => {
      try {
        const status = await evren.status({})
        const view = viewOf(status)
        await updateState((draft) => {
          draft.quota = view.quota
          draft.connected = view.connected
          draft.error = view.error
        })
        if (view.connected && view.quota.level !== lastLevel) {
          lastLevel = view.quota.level
          if (view.quota.level !== "ok") {
            context.ui.toast.show({
              title: "EVREN",
              message: `Kota seviyesi: ${view.quota.level} (kalan CR: ${view.quota.remaining})`,
              variant: "warning",
              duration: 5000,
            })
          }
        }
      } catch {
        // Sunucuya ulaşılamıyorsa sessizce eski değer korunur.
      }
    }

    await refresh()
    const timer = setInterval(() => void refresh(), 60_000)
    const unsubscribe = evren.events.on("updated", () => void refresh())

    const unslot = context.ui.slot({
      append: "sidebar.footer",
      render: () => {
        if (!state.connected) return <text>EVREN: bağlı değil</text>
        return (
          <text>
            EVREN CR {state.quota.remaining} · {state.quota.level} · gün {fmtDaily(state.quota.daily)}
          </text>
        )
      },
    })

    return () => {
      clearInterval(timer)
      unsubscribe()
      unslot()
    }
  },
})
