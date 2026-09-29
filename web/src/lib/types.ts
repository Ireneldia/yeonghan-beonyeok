export type Provider = "codex" | "local" | "claude"
export type Engine = {
  provider: Provider
  model: string
  effort: string
  fast: boolean
}
export type Settings = {
  provider: Provider
  codex_model: string
  local_model: string
  claude_model: string
  codex_effort: string
  local_effort: string
  claude_effort: string
  codex_fast: boolean
}
export type Fit = {
  level: "green" | "yellow" | "red" | "unknown"
  label?: string
}
export type Model = {
  id: string
  name: string
  efforts: { id: string; name: string }[]
  fast?: boolean
  fit?: Fit
}
export type Models = {
  codex: Model[]
  local: Model[]
  claude: Model[]
  errors: Partial<Record<Provider, string>>
  gpu: { state: "gpu" | "cpu" | "unloaded" | "unavailable"; model?: string }
  hardware?: { name: string; total_bytes: number | null }
}
export type CatalogModel = {
  id: string
  name: string
  size?: string
  fit?: Fit
}
export type Download = {
  state: "idle" | "downloading" | "done" | "error"
  model?: string
  status?: string
  completed?: number
  total?: number
  percent?: number | null
  total_known?: boolean
  error?: string
}
export type Doc = {
  id: string
  name: string
  subject: string
  folder_id: string | null
  pages: number
  created: number
}
export type Folder = {
  id: string
  name: string
  created: number
  doc_count: number
}
export type Word = {
  i: number
  t: string
  x0: number
  y0: number
  x1: number
  y1: number
  b: number
  l: number
  s?: number
  gap?: number
  join?: number
}
export type Sentence = { i: number; w: number[]; t: string }
export type PageMeta = {
  words: Word[]
  sentences: Sentence[]
  w: number
  h: number
  right?: number
}
export type LookupInput = {
  page: number
  kind: "word" | "sentence"
  text: string
  word_ids: number[]
}
export type Lookup = LookupInput & {
  id: number
  doc_id: string
  status: "pending" | "done" | "error"
  error?: string | null
  result?: { meaning?: string; translation?: string; note?: string } | null
  provider?: string
  model?: string
  effort?: string
  fast?: boolean
}
export type Question = {
  id: number
  doc_id?: string
  text: string
  raw: string
  provider?: string
  model?: string
  effort?: string
  fast?: boolean
  error?: string | null
}
export type Vocab = {
  id: number
  word: string
  meaning: string
  subject: string
  doc: string
  page: number
}
export type SpeechSettings = {
  model: string
  language: "auto" | "ko" | "en"
  term_hints: boolean
}
export type SpeechContext = {
  docId: string
  page: number
  engine: Engine | null
  stt: SpeechSettings | null
}
export type QuestionDraft = {
  id: string | number
  docId: string
  raw: string
  stage: string
  failed?: boolean
}
