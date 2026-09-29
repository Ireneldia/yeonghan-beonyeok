import { useCallback, useEffect, useRef, useState } from "react"
import { toast } from "sonner"
import { api } from "@/lib/api"
import type { Models, Settings } from "@/lib/types"

export function useModels() {
  const [settings, setSettings] = useState<Settings | null>(null)
  const [models, setModels] = useState<Models | null>(null)
  const [busy, setBusy] = useState(true)
  const sequence = useRef({ revision: 0, saving: false })
  const refresh = useCallback(async (force = false, readSettings = true) => {
    const guard = sequence.current
    if (guard.saving) return
    const request = ++guard.revision
    await Promise.all([
      readSettings &&
        api<Settings>("/api/llm/settings").then(
          (value) => {
            if (request === guard.revision) setSettings(value)
          },
          (error) => {
            if (request === guard.revision)
              toast.error("모델 설정을 불러오지 못했습니다", {
                description: String(error),
              })
          }
        ),
      api<Models>(`/api/llm/models${force ? "?refresh=true" : ""}`).then(
        (value) => {
          if (request === guard.revision) setModels(value)
        },
        () => {
          if (request === guard.revision)
            toast.error("모델 목록을 불러오지 못했습니다")
        }
      ),
    ])
    if (request === guard.revision) setBusy(false)
  }, [])
  useEffect(() => {
    const guard = sequence.current
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
      await refresh(false, false)
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
      if (sequence.current.saving) return
      setBusy(true)
      await refresh(true)
    },
    change,
  }
}
