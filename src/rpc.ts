import { Rpc } from "@opencode/plugin/rpc"

/**
 * Server (index.ts) <-> TUI (tui.tsx) paylaşımlı RPC sözleşmesi.
 *
 * `status` o anki anlık görüntüyü döner: GET /v1/quota kotası, kullanım
 * şartları durumu, gerçek yanıtlardan yakalanan X-Evren-* başlıkları ve
 * model envanteri. `updated` anlık görüntü her değiştiğinde ateşlenir,
 * sidebar polling yapmadan tepki verir.
 */
export const Evren = Rpc.define({
  id: "evren",
  methods: {
    status: {
      input: { type: "object", properties: {}, additionalProperties: false },
      output: { type: "object", additionalProperties: true },
    },
  },
  events: {
    updated: {
      schema: {
        type: "object",
        properties: { at: { type: "string" } },
        required: ["at"],
        additionalProperties: false,
      },
    },
  },
})
