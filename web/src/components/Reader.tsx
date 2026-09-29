import { useCallback, useEffect, useRef, useState, type ReactNode } from "react"
import {
  ChevronLeft,
  ChevronRight,
  Download,
  Loader2,
  MessageSquare,
  Mic,
  RefreshCw,
  Square,
  Volume2,
  ZoomIn,
  ZoomOut,
} from "lucide-react"
import { toast } from "sonner"
import { api } from "@/lib/api"
import { readRoute } from "@/lib/reader"
import type {
  Doc,
  Engine,
  Lookup,
  LookupInput,
  PageMeta,
  SpeechContext,
  SpeechSettings,
} from "@/lib/types"
import { useSpeech } from "@/hooks/useSpeech"
import { useIsMobile } from "@/hooks/use-mobile"
import { PdfViewer } from "@/components/PdfViewer"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
} from "@/components/ui/resizable"
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet"

type Props = {
  doc: Doc | null
  page: number
  reload: number
  readerError: string
  lookups: Lookup[]
  engine: Engine | null
  speechSettings: SpeechSettings | null
  exporting: boolean
  notes: ReactNode
  onReload: () => void
  onExport: () => void
  onTabChange: (tab: string) => void
  onVisiblePageChange: (page: number) => void
  onOpenSpeechSettings: () => void
  onLookup: (id: string, input: LookupInput) => Promise<boolean>
  onAudio: (blob: Blob, context: SpeechContext) => Promise<void>
}

export function Reader({
  doc,
  page,
  reload,
  readerError,
  lookups,
  engine,
  speechSettings,
  exporting,
  notes,
  onReload,
  onExport,
  onTabChange,
  onVisiblePageChange,
  onOpenSpeechSettings,
  onLookup,
  onAudio,
}: Props) {
  const mobile = useIsMobile()
  const [pageData, setPageData] = useState<{
    key: string
    meta: PageMeta
  } | null>(null)
  const [zoom, setZoom] = useState(0)
  const [pdfView, setPdfView] = useState<"page" | "continuous">(() => {
    try {
      return localStorage.getItem("yeonghan-pdf-view") === "continuous"
        ? "continuous"
        : "page"
    } catch {
      return "page"
    }
  })
  const [notesOpen, setNotesOpen] = useState(false)
  const [flash, setFlash] = useState<{
    docId: string
    page: number
    ids: number[]
  } | null>(null)
  const flashTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pageKey = `${doc?.id}:${page}`
  const meta = pageData?.key === pageKey ? pageData.meta : null
  const flashWordIds =
    flash?.docId === doc?.id && flash?.page === page ? flash.ids : []
  const pageMetaLoaded = useCallback(
    (id: string, next: number, value: PageMeta) => {
      if (readRoute().docId === id)
        setPageData({ key: `${id}:${next}`, meta: value })
    },
    []
  )
  const lookup = useCallback(
    async (id: string, input: LookupInput) => {
      if ((await onLookup(id, input)) && mobile && readRoute().docId === id)
        setNotesOpen(true)
    },
    [onLookup, mobile]
  )
  useEffect(() => {
    if (!doc) return
    const keydown = (event: KeyboardEvent) => {
      if (event.defaultPrevented) return
      if (
        (event.target as HTMLElement)?.closest(
          "input,textarea,[contenteditable=true],[role=combobox],[role=listbox],[role=dialog],[role=menu]"
        )
      )
        return
      if (event.ctrlKey || event.metaKey) {
        if (["=", "+", "-", "0"].includes(event.key)) {
          event.preventDefault()
          setZoom((current) =>
            event.key === "0"
              ? 0
              : Math.min(
                  4,
                  Math.max(
                    0.4,
                    (current || 1) * (event.key === "-" ? 1 / 1.15 : 1.15)
                  )
                )
          )
        }
      } else if (
        ["ArrowLeft", "PageUp", "ArrowRight", "PageDown"].includes(event.key)
      ) {
        if (
          pdfView === "continuous" &&
          ["PageUp", "PageDown"].includes(event.key)
        ) {
          const viewport =
            document.querySelector<HTMLElement>("[data-pdf-scroll]")
          if (viewport) {
            event.preventDefault()
            viewport.scrollBy({
              top:
                viewport.clientHeight * 0.9 * (event.key === "PageUp" ? -1 : 1),
            })
          }
          return
        }
        event.preventDefault()
        const next =
          page + (["ArrowLeft", "PageUp"].includes(event.key) ? -1 : 1)
        location.hash = `#/doc/${doc.id}/${Math.max(0, Math.min(doc.pages - 1, next)) + 1}`
      }
    }
    window.addEventListener("keydown", keydown)
    return () => window.removeEventListener("keydown", keydown)
  }, [doc, page, pdfView])
  useEffect(
    () => () => {
      if (flashTimer.current) clearTimeout(flashTimer.current)
    },
    []
  )

  const receiveRead = async (text: string, context: SpeechContext) => {
    const match = await api<{
      kind?: "word" | "sentence"
      word_ids?: number[]
      text?: string
    }>(`/api/docs/${context.docId}/match`, {
      method: "POST",
      body: JSON.stringify({ page: context.page, transcript: text }),
    })
    const current = readRoute()
    if (current.docId !== context.docId || current.page !== context.page) return
    if (!match.kind || !match.word_ids?.length) {
      toast("이 페이지에서 해당 표현을 찾지 못했어요", { description: text })
      return
    }
    let ids = match.word_ids
    if (
      match.kind === "word" &&
      ids.length === 1 &&
      meta?.words[ids[0]]?.join != null
    )
      ids = [ids[0], meta.words[ids[0]].join!]
    const selectedText =
      match.kind === "sentence"
        ? match.text || text
        : ids.map((i) => meta?.words[i]?.t || "").join(" ") ||
          match.text ||
          text
    setFlash({ docId: context.docId, page: context.page, ids })
    if (flashTimer.current) clearTimeout(flashTimer.current)
    flashTimer.current = setTimeout(() => setFlash(null), 1200)
    await lookup(context.docId, {
      page: context.page,
      kind: match.kind,
      text: selectedText,
      word_ids: ids,
    })
  }
  const speech = useSpeech({
    context: doc ? { docId: doc.id, page, engine, stt: speechSettings } : null,
    onRead: receiveRead,
    onAudio,
    onError: (message) => toast.error(message),
  })

  return (
    <>
      <div className="flex min-h-0 flex-1 flex-col">
        <div className="flex min-h-14 shrink-0 flex-wrap items-center gap-2 border-b bg-background/95 px-4 py-2">
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="이전 페이지"
            disabled={!doc || page <= 0}
            onClick={() => {
              location.hash = `#/doc/${doc!.id}/${page}`
            }}
          >
            <ChevronLeft />
          </Button>
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <Input
              key={`${doc?.id}:${page}`}
              type="number"
              min={1}
              max={doc?.pages}
              defaultValue={page + 1}
              aria-label="페이지"
              className="h-7 w-14 text-center"
              onBlur={(e) => {
                if (doc)
                  location.hash = `#/doc/${doc.id}/${Math.min(doc.pages, Math.max(1, Number(e.target.value) || 1))}`
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter") e.currentTarget.blur()
              }}
            />
            <span>/ {doc?.pages ?? "—"}</span>
          </div>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="다음 페이지"
            disabled={!doc || page >= doc.pages - 1}
            onClick={() => {
              location.hash = `#/doc/${doc!.id}/${page + 2}`
            }}
          >
            <ChevronRight />
          </Button>
          <span className="mx-1 h-5 w-px bg-border" />
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="축소"
            onClick={() => setZoom((z) => Math.max(0.4, (z || 1) / 1.15))}
          >
            <ZoomOut />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="w-12 tabular-nums"
            onClick={() => setZoom(0)}
          >
            {zoom ? `${Math.round(zoom * 100)}%` : "맞춤"}
          </Button>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="확대"
            onClick={() => setZoom((z) => Math.min(4, (z || 1) * 1.15))}
          >
            <ZoomIn />
          </Button>
          <Select
            value={pdfView}
            onValueChange={(value) => {
              if (value !== "page" && value !== "continuous") return
              setPdfView(value)
              try {
                localStorage.setItem("yeonghan-pdf-view", value)
              } catch {
                /* 저장 없이도 보기 전환은 가능하다. */
              }
            }}
          >
            <SelectTrigger
              size="sm"
              aria-label="PDF 보기 방식"
              className="w-32 text-xs"
            >
              <SelectValue>
                {pdfView === "continuous" ? "연속 스크롤" : "한 페이지"}
              </SelectValue>
            </SelectTrigger>
            <SelectContent alignItemWithTrigger={false}>
              <SelectItem value="page">한 페이지</SelectItem>
              <SelectItem value="continuous">연속 스크롤</SelectItem>
            </SelectContent>
          </Select>
          <span className="mx-1 hidden h-5 w-px bg-border sm:block" />
          <Button
            variant={speech.mode === "read" ? "secondary" : "ghost"}
            size="sm"
            disabled={!doc || !meta || speech.starting}
            onClick={speech.toggleRead}
          >
            {speech.mode === "read" ? (
              <Square className="text-destructive" />
            ) : (
              <Volume2 />
            )}
            읽기
          </Button>
          <Button
            variant={speech.mode === "ask" ? "destructive" : "ghost"}
            size="sm"
            disabled={!doc || speech.starting}
            onClick={() => {
              if (!speech.mode && !speechSettings?.model) {
                onOpenSpeechSettings()
                return
              }
              onTabChange("questions")
              speech.toggleAsk()
            }}
          >
            {speech.mode === "ask" ? <Square /> : <Mic />}질문
            {speech.mode === "ask" && (
              <span className="tabular-nums">
                {Math.floor(speech.elapsed / 60)}:
                {String(speech.elapsed % 60).padStart(2, "0")}
              </span>
            )}
          </Button>
          <span
            role="status"
            className="min-w-0 flex-1 truncate text-xs text-muted-foreground"
          >
            {speech.starting ? "마이크 연결 중…" : speech.interim}
          </span>
          {mobile && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => setNotesOpen(true)}
            >
              <MessageSquare />
              메모
            </Button>
          )}
          <Button
            variant="outline"
            size="sm"
            disabled={!doc || exporting}
            onClick={() => onExport()}
          >
            {exporting ? <Loader2 className="animate-spin" /> : <Download />}
            <span className="hidden sm:inline">PDF 내보내기</span>
          </Button>
        </div>
        {readerError ? (
          <div className="m-auto max-w-sm space-y-4 p-8 text-center">
            <p className="text-sm text-destructive">{readerError}</p>
            <Button variant="outline" onClick={onReload}>
              <RefreshCw />
              다시 불러오기
            </Button>
          </div>
        ) : !doc ? (
          <div className="space-y-4 p-8">
            <Skeleton className="h-6 w-40" />
            <Skeleton className="h-96 w-full" />
          </div>
        ) : mobile ? (
          <div className="min-h-0 flex-1">
            <PdfViewer
              key={`${doc.id}:${reload}`}
              doc={doc}
              page={page}
              mode={pdfView}
              lookups={lookups}
              zoom={zoom}
              onLookup={(input) => void lookup(doc.id, input)}
              flashWordIds={flashWordIds}
              onPageChange={onVisiblePageChange}
              onPageMeta={pageMetaLoaded}
            />
          </div>
        ) : (
          <ResizablePanelGroup
            orientation="horizontal"
            className="min-h-0 flex-1"
          >
            <ResizablePanel defaultSize="68%" minSize="40%">
              <PdfViewer
                key={`${doc.id}:${reload}`}
                doc={doc}
                page={page}
                mode={pdfView}
                lookups={lookups}
                zoom={zoom}
                onLookup={(input) => void lookup(doc.id, input)}
                flashWordIds={flashWordIds}
                onPageChange={onVisiblePageChange}
                onPageMeta={pageMetaLoaded}
              />
            </ResizablePanel>
            <ResizableHandle withHandle />
            <ResizablePanel defaultSize="32%" minSize="25%">
              {notes}
            </ResizablePanel>
          </ResizablePanelGroup>
        )}
      </div>
      <Sheet open={notesOpen && mobile && !!doc} onOpenChange={setNotesOpen}>
        <SheetContent side="right" className="gap-0 p-0">
          <SheetHeader className="border-b p-4">
            <SheetTitle>교안 메모</SheetTitle>
          </SheetHeader>
          {notes}
        </SheetContent>
      </Sheet>
    </>
  )
}
