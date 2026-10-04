import { useEffect, useRef, useState, type CSSProperties } from "react"
import {
  BookOpen,
  Copy,
  Loader2,
  MessageSquare,
  Minus,
  Pencil,
  Plus,
  RotateCcw,
  Trash2,
} from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs"
import { Textarea } from "@/components/ui/textarea"
import { ScrollArea } from "@/components/ui/scroll-area"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import type { Lookup, Question, QuestionDraft } from "@/lib/types"

export type PendingQuestion = QuestionDraft
type Props = {
  lookups: Lookup[]
  questions: Question[]
  pendingQuestions: PendingQuestion[]
  tab: string
  onTabChange: (value: string) => void
  onDeleteLookup: (id: number) => void
  onRetry: (id: number) => void
  onAdd: (text: string) => Promise<boolean>
  onCopy: () => void
  onEdit: (id: number, text: string) => Promise<void>
  onDeleteQuestion: (id: number) => void
  onSaveDraft: (draft: QuestionDraft) => Promise<void>
  onDeleteDraft: (id: string | number) => void
}

function Source({ value }: { value: Lookup | Question }) {
  if (!value.model) return null
  return (
    <span
      className="text-[11px] text-muted-foreground"
      title={[value.model, value.effort, value.fast && "Fast"]
        .filter(Boolean)
        .join(" · ")}
    >
      {(
        { codex: "Codex", local: "로컬", claude: "Claude" } as Record<
          string,
          string
        >
      )[value.provider ?? ""] ?? value.provider}
    </span>
  )
}

const SCALE_KEY = "yh-notes-scale"
const clampScale = (value: number) =>
  Math.round(Math.min(2, Math.max(0.8, value)) * 10) / 10

export function NotesPanel(props: Props) {
  // 메모 패널 글자 크기. 패널 위에 마우스를 두고 ⌘/Ctrl + -, +, 0 으로도 조절한다.
  const [scale, setScale] = useState(() => {
    try {
      const saved = Number(localStorage.getItem(SCALE_KEY))
      return saved ? clampScale(saved) : 1
    } catch {
      return 1
    }
  })
  const hovering = useRef(false)
  useEffect(() => {
    try {
      localStorage.setItem(SCALE_KEY, String(scale))
    } catch {
      /* 저장 실패는 무시 */
    }
  }, [scale])
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      if (!hovering.current || !(event.metaKey || event.ctrlKey)) return
      if (!["=", "+", "-", "0"].includes(event.key)) return
      event.preventDefault() // 브라우저 줌과 PDF 줌 대신 패널 글자만 조절
      setScale((current) =>
        event.key === "0"
          ? 1
          : clampScale(current + (event.key === "-" ? -0.1 : 0.1))
      )
    }
    window.addEventListener("keydown", keydown, true)
    return () => window.removeEventListener("keydown", keydown, true)
  }, [])
  const zoomStyle = { zoom: scale } as CSSProperties
  const [input, setInput] = useState("")
  const [adding, setAdding] = useState(false)
  const [editing, setEditing] = useState<Question | null>(null)
  const [draft, setDraft] = useState("")
  const [saving, setSaving] = useState(false)
  const [draftBusy, setDraftBusy] = useState(false)
  const words = props.lookups.filter((row) => row.kind === "word")
  const sentences = props.lookups.filter((row) => row.kind === "sentence")
  const add = async () => {
    const raw = input.trim()
    if (!raw || adding) return
    setAdding(true)
    if (await props.onAdd(raw))
      setInput((current) => (current.trim() === raw ? "" : current))
    setAdding(false)
  }
  const rows = (items: Lookup[]) =>
    items.length ? (
      items.map((row) => (
        <article
          key={row.id}
          className="group rounded-xl border bg-card p-4 shadow-xs"
        >
          <div className="mb-2 flex items-start justify-between gap-2">
            <h3 className="text-sm leading-relaxed font-semibold break-words">
              {row.text}
            </h3>
            <Button
              variant="ghost"
              size="icon-xs"
              aria-label={`${row.text} 삭제`}
              onClick={() => props.onDeleteLookup(row.id)}
            >
              <Trash2 className="size-3.5" />
            </Button>
          </div>
          {row.status === "done" ? (
            <>
              <p className="text-sm leading-relaxed font-medium whitespace-pre-wrap text-primary">
                {row.result?.meaning ?? row.result?.translation}
              </p>
              {row.result?.note && (
                <p className="mt-2 text-[13px] leading-6 whitespace-pre-wrap text-foreground/75">
                  {row.result.note}
                </p>
              )}
            </>
          ) : row.status === "error" ? (
            <div className="space-y-2">
              <p className="text-xs leading-relaxed text-destructive">
                {row.error || "처리하지 못했습니다."}
              </p>
              <Button
                variant="outline"
                size="sm"
                onClick={() => props.onRetry(row.id)}
              >
                <RotateCcw />
                다시 시도
              </Button>
            </div>
          ) : (
            <p className="flex items-center gap-2 py-1 text-xs text-muted-foreground">
              <Loader2 className="size-3.5 animate-spin" />
              뜻을 살펴보고 있어요
            </p>
          )}
          <div className="mt-3">
            <Source value={row} />
          </div>
        </article>
      ))
    ) : (
      <div className="px-4 py-12 text-center text-muted-foreground">
        <BookOpen className="mx-auto mb-3 size-7 opacity-40" />
        <p className="text-sm">궁금한 부분을 선택해 보세요</p>
        <p className="mt-2 text-xs leading-5">
          단어는 클릭하고,
          <br />
          문장은 드래그하면 됩니다.
        </p>
      </div>
    )

  return (
    <>
      <Tabs
        value={props.tab}
        onValueChange={(value) => props.onTabChange(String(value))}
        className="h-full min-h-0 gap-0 bg-background"
        onMouseEnter={() => {
          hovering.current = true
        }}
        onMouseLeave={() => {
          hovering.current = false
        }}
      >
        <div className="flex items-center gap-2 border-b px-4 py-3">
          <TabsList className="min-w-0 flex-1">
            <TabsTrigger value="words">
              단어
              {words.length > 0 && (
                <span className="text-xs opacity-60">{words.length}</span>
              )}
            </TabsTrigger>
            <TabsTrigger value="sentences">
              문장
              {sentences.length > 0 && (
                <span className="text-xs opacity-60">{sentences.length}</span>
              )}
            </TabsTrigger>
            <TabsTrigger value="questions">
              질문
              {props.questions.length > 0 && (
                <span className="text-xs opacity-60">
                  {props.questions.length}
                </span>
              )}
            </TabsTrigger>
          </TabsList>
          <div
            className="flex shrink-0 items-center"
            title="글자 크기 (패널 위에서 ⌘− / ⌘+ / ⌘0)"
          >
            <Button
              size="icon-sm"
              variant="ghost"
              aria-label="글자 작게"
              disabled={scale <= 0.8}
              onClick={() => setScale((current) => clampScale(current - 0.1))}
            >
              <Minus />
            </Button>
            <button
              type="button"
              className="w-10 text-center text-xs text-muted-foreground tabular-nums"
              aria-label="글자 크기 초기화"
              onClick={() => setScale(1)}
            >
              {Math.round(scale * 100)}%
            </button>
            <Button
              size="icon-sm"
              variant="ghost"
              aria-label="글자 크게"
              disabled={scale >= 2}
              onClick={() => setScale((current) => clampScale(current + 0.1))}
            >
              <Plus />
            </Button>
          </div>
        </div>
        <TabsContent value="words" className="min-h-0 overflow-hidden">
          <ScrollArea className="h-full">
            <div className="space-y-3 p-4" style={zoomStyle}>{rows(words)}</div>
          </ScrollArea>
        </TabsContent>
        <TabsContent value="sentences" className="min-h-0 overflow-hidden">
          <ScrollArea className="h-full">
            <div className="space-y-3 p-4" style={zoomStyle}>{rows(sentences)}</div>
          </ScrollArea>
        </TabsContent>
        <TabsContent
          value="questions"
          className="flex min-h-0 flex-col overflow-hidden"
        >
          <div className="space-y-2 border-b p-4" style={zoomStyle}>
            <Textarea
              aria-label="새 질문"
              placeholder="궁금한 점을 남겨 보세요"
              value={input}
              onChange={(event) => setInput(event.target.value)}
              className="min-h-20 resize-none"
            />
            <div className="flex justify-between">
              <Button variant="ghost" size="sm" onClick={props.onCopy}>
                <Copy />
                전체 복사
              </Button>
              <Button
                size="sm"
                disabled={adding || !input.trim()}
                onClick={() => void add()}
              >
                {adding ? <Loader2 className="animate-spin" /> : <Plus />}질문
                추가
              </Button>
            </div>
          </div>
          <ScrollArea className="min-h-0 flex-1">
            <div className="space-y-3 p-4" style={zoomStyle}>
              {props.questions.map((q) => (
                <article
                  key={q.id}
                  className="rounded-xl border bg-card p-4 shadow-xs"
                >
                  <p className="text-sm leading-6 whitespace-pre-wrap">
                    {q.text}
                  </p>
                  {q.raw && q.raw !== q.text && (
                    <p className="mt-2 text-xs leading-5 whitespace-pre-wrap text-muted-foreground">
                      원문 · {q.raw}
                    </p>
                  )}
                  <div className="mt-3 flex items-center justify-between">
                    <Source value={q} />
                    <div className="flex gap-1">
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        aria-label="질문 수정"
                        onClick={() => {
                          setEditing(q)
                          setDraft(q.text)
                        }}
                      >
                        <Pencil className="size-3.5" />
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        aria-label="질문 삭제"
                        onClick={() => props.onDeleteQuestion(q.id)}
                      >
                        <Trash2 className="size-3.5" />
                      </Button>
                    </div>
                  </div>
                </article>
              ))}
              {props.pendingQuestions.map((q) => (
                <article
                  key={q.id}
                  className="rounded-xl border border-dashed p-4"
                >
                  <p className="flex items-center gap-2 text-sm text-primary">
                    {q.failed ? (
                      <MessageSquare className="size-4 text-orange-500" />
                    ) : (
                      <Loader2 className="size-4 animate-spin" />
                    )}
                    {q.stage}
                  </p>
                  {q.raw && (
                    <p className="mt-2 text-xs leading-5 text-muted-foreground">
                      {q.raw}
                    </p>
                  )}
                  {q.failed && (
                    <div className="mt-3 flex gap-2">
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={draftBusy}
                        onClick={async () => {
                          setDraftBusy(true)
                          try {
                            await props.onSaveDraft(q)
                          } finally {
                            setDraftBusy(false)
                          }
                        }}
                      >
                        원문 저장
                      </Button>
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => {
                          void navigator.clipboard
                            .writeText(q.raw)
                            .then(() => toast.success("원문을 복사했어요"))
                            .catch(() => toast.error("복사하지 못했습니다"))
                        }}
                      >
                        복사
                      </Button>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        aria-label="임시 질문 삭제"
                        disabled={draftBusy}
                        onClick={() => props.onDeleteDraft(q.id)}
                      >
                        <Trash2 />
                      </Button>
                    </div>
                  )}
                </article>
              ))}
              {!props.questions.length && !props.pendingQuestions.length && (
                <div className="py-8 text-center text-muted-foreground">
                  <MessageSquare className="mx-auto mb-3 size-7 opacity-40" />
                  <p className="text-sm">질문을 모아두는 곳</p>
                  <p className="mt-2 text-xs">
                    말하거나 직접 입력해 남길 수 있어요.
                  </p>
                </div>
              )}
            </div>
          </ScrollArea>
        </TabsContent>
      </Tabs>
      <Dialog
        open={!!editing}
        onOpenChange={(open) => {
          if (!open && !saving) setEditing(null)
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>질문 수정</DialogTitle>
            <DialogDescription>
              질문을 원하는 표현으로 다듬어 주세요.
            </DialogDescription>
          </DialogHeader>
          <Textarea
            aria-label="질문 내용"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            className="min-h-32"
          />
          <DialogFooter>
            <Button
              variant="outline"
              disabled={saving}
              onClick={() => setEditing(null)}
            >
              취소
            </Button>
            <Button
              disabled={saving || !draft.trim()}
              onClick={async () => {
                if (!editing) return
                setSaving(true)
                try {
                  await props.onEdit(editing.id, draft.trim())
                  setEditing(null)
                } catch (error) {
                  toast.error("수정하지 못했습니다", {
                    description: String(error),
                  })
                } finally {
                  setSaving(false)
                }
              }}
            >
              {saving && <Loader2 className="animate-spin" />}저장
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
