import type { Engine, Lookup, Settings, QuestionDraft } from "./types"

const DRAFT_KEY = "yeonghan-question-drafts"
export function loadQuestionDrafts(
  storage: Pick<Storage, "getItem"> = localStorage
): QuestionDraft[] {
  try {
    const rows: unknown = JSON.parse(storage.getItem(DRAFT_KEY) || "[]")
    if (!Array.isArray(rows)) return []
    return rows
      .filter(
        (q): q is QuestionDraft =>
          !!q &&
          (typeof q.id === "string" ||
            (typeof q.id === "number" && Number.isFinite(q.id))) &&
          typeof q.docId === "string" &&
          typeof q.raw === "string" &&
          !!q.raw
      )
      .map((q) => ({ ...q, failed: true, stage: "저장 대기 중인 질문" }))
  } catch {
    return []
  }
}
export function persistQuestionDrafts(
  rows: QuestionDraft[],
  storage: Pick<Storage, "setItem"> = localStorage
): boolean {
  try {
    storage.setItem(DRAFT_KEY, JSON.stringify(rows.filter((q) => q.raw)))
    return true
  } catch {
    return false
  }
}

export function readRoute(hash = window.location.hash) {
  const match = hash.match(/^#\/doc\/([^/]+)(?:\/(\d+))?$/)
  return {
    docId: match?.[1] ?? null,
    folderId: hash.match(/^#\/folder\/([^/]+)$/)?.[1] ?? null,
    page: Math.max(0, Number(match?.[2] ?? 1) - 1),
    view: hash === "#/vocab" ? "vocab" : "library",
  }
}

export function selectedEngine(settings: Settings | null): Engine | null {
  if (!settings) return null
  const provider = settings.provider
  return {
    provider,
    model: settings[`${provider}_model`],
    effort: settings[`${provider}_effort`],
    fast: provider === "codex" && settings.codex_fast,
  }
}

export function mergeLookup(rows: Lookup[], item: Lookup): Lookup[] {
  return [
    ...rows.filter(
      (row) =>
        row.id !== item.id &&
        !(
          row.page === item.page &&
          row.kind === item.kind &&
          row.text === item.text &&
          JSON.stringify(row.word_ids) === JSON.stringify(item.word_ids)
        )
    ),
    item,
  ].sort((a, b) => a.id - b.id)
}
