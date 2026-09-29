import { useCallback, useEffect, useRef, useState } from "react"
import { toast } from "sonner"
import { api } from "@/lib/api"
import type { Models, Settings } from "@/lib/types"

export function useModels() {
  const [settings, setSettings] = useState<Settings | null>(null)
  const [models, setModels] = useState<Models | null>(null)
  const [busy, setBusy] = useState(true)
  const sequence = useRef({ revision: 0, saving: false })
  const refresh = useCallback(async () => {
    const guard = sequence.current
    if (guard.saving) return
    const request = ++guard.revision
    const [s, m] = await Promise.allSettled([
      api<Settings>("/api/llm/settings"),
      api<Models>("/api/llm/models"),
    ])
    if (request !== guard.revision) return
    if (s.status === "fulfilled") setSettings(s.value)
    else
      toast.error("모델 설정을 불러오지 못했습니다", {
        description: String(s.reason),
      })
    if (m.status === "fulfilled") setModels(m.value)
    else toast.error("모델 목록을 불러오지 못했습니다")
    setBusy(false)
  }, [])
  useEffect(() => {
    const guard = sequence.current
    // Response handlers update state after I/O; this effect does not set state synchronously.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void refresh()
    return () => {
      guard.revision++
      guard.saving = false
    }
  }, [refresh])
  const change = async (next: Settings) => {
    const guard = sequence.current
    if (guard.saving) return
    const request = ++guard.revision
    guard.saving = true
    setBusy(true)
    try {
      const saved = await api<Settings>("/api/llm/settings", {
        method: "PUT",
        body: JSON.stringify(next),
      })
      if (request !== guard.revision) return
      setSettings(saved)
      guard.saving = false
      await refresh()
    } catch (error) {
      if (request === guard.revision) {
        guard.saving = false
        setBusy(false)
        toast.error("설정을 저장하지 못했습니다", {
          description: String(error),
        })
      }
    }
  }
  return {
    settings,
    models,
    busy,
    refresh: async () => {
      setBusy(true)
      await refresh()
    },
    change,
  }
}
