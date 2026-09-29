import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { api } from "@/lib/api"
import type { Doc, Lookup, LookupInput, PageMeta } from "@/lib/types"
import { PdfPage } from "./PdfPage"
import "./pdf-page.css"

type Props = {
  doc: Doc
  page: number
  mode: "page" | "continuous"
  zoom: number
  lookups: Lookup[]
  onLookup: (input: LookupInput) => void
  flashWordIds?: number[]
  onPageChange: (page: number) => void
  onPageMeta: (docId: string, page: number, meta: PageMeta) => void
}
type PageSize = { w: number; h: number }
type Layout = { top: number; height: number }
const padding = 24
const gap = 24

function pageLayout(sizes: PageSize[], width: number): Layout[] {
  let top = padding
  return sizes.map(({ w, h }) => {
    const page = { top, height: (width * h) / w }
    top += page.height + gap
    return page
  })
}
function pageAt(layout: Layout[], position: number): number {
  const index = layout.findIndex(
    (page, i) =>
      position < page.top + page.height + (i < layout.length - 1 ? gap / 2 : 0)
  )
  return index < 0 ? Math.max(0, layout.length - 1) : index
}

function PageSlot({
  doc,
  page,
  active,
  cache,
  zoom,
  lookups,
  onLookup,
  onPageMeta,
  flashWordIds,
  embedded = false,
}: {
  doc: Doc
  page: number
  active: boolean
  cache: Map<number, PageMeta>
  zoom: number
  lookups: Lookup[]
  onLookup: Props["onLookup"]
  onPageMeta: Props["onPageMeta"]
  flashWordIds?: number[]
  embedded?: boolean
}) {
  const [meta, setMeta] = useState<PageMeta | null>(
    () => cache.get(page) ?? null
  )
  const [error, setError] = useState("")
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    if (cache.has(page)) return
    const controller = new AbortController()
    api<PageMeta>(`/api/docs/${encodeURIComponent(doc.id)}/page/${page}/meta`, {
      signal: controller.signal,
    })
      .then((value) => {
        if (controller.signal.aborted) return
        cache.set(page, value)
        setMeta(value)
      })
      .catch((reason: unknown) => {
        if (!controller.signal.aborted)
          setError(
            reason instanceof Error
              ? reason.message
              : "페이지 정보를 불러오지 못했습니다."
          )
      })
    return () => controller.abort()
  }, [doc.id, page, cache, attempt])
  useEffect(() => {
    if (active && meta) onPageMeta(doc.id, page, meta)
  }, [active, meta, doc.id, page, onPageMeta])
  return (
    <div className="pdf-viewer-page">
      {error ? (
        <div className="pdf-page-message" role="alert">
          <span>{page + 1}쪽 정보를 불러오지 못했습니다.</span>
          <span className="text-xs text-muted-foreground">{error}</span>
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              setError("")
              setAttempt((value) => value + 1)
            }}
          >
            다시 시도
          </Button>
        </div>
      ) : (
        <PdfPage
          doc={doc}
          page={page}
          meta={meta}
          zoom={zoom}
          embedded={embedded}
          lookups={lookups}
          onLookup={onLookup}
          flashWordIds={active ? flashWordIds : undefined}
        />
      )}
    </div>
  )
}

// Each document owns its cache and requests. Page changes preserve the scrolling viewport.
export function PdfViewer(props: Props) {
  return <DocumentViewer key={props.doc.id} {...props} />
}

function DocumentViewer({
  doc,
  page,
  mode,
  zoom,
  lookups,
  onLookup,
  flashWordIds,
  onPageChange,
  onPageMeta,
}: Props) {
  const [cache] = useState(() => new Map<number, PageMeta>())
  const [sizes, setSizes] = useState<PageSize[]>([])
  const [geometryError, setGeometryError] = useState("")
  const [geometryAttempt, setGeometryAttempt] = useState(0)
  const [viewport, setViewport] = useState({ width: 0, height: 0, top: 0 })
  const scrollRef = useRef<HTMLDivElement>(null)
  const callbacks = useRef({ onPageChange, onPageMeta, onLookup })
  const activePage = useRef(page)
  const reportedPage = useRef<number | null>(null)
  const programmaticTop = useRef<number | null>(null)
  const anchor = useRef({ page, ratio: 0 })
  const positioned = useRef<{
    page: number
    layout: Layout[]
    height: number
  } | null>(null)
  const width = Math.max(1, viewport.width - padding * 2) * (zoom || 1)
  const layout = useMemo(() => pageLayout(sizes, width), [sizes, width])

  useLayoutEffect(() => {
    callbacks.current = { onPageChange, onPageMeta, onLookup }
    activePage.current = page
  }, [page, onPageChange, onPageMeta, onLookup])

  useEffect(() => {
    const controller = new AbortController()
    api<PageSize[]>(`/api/docs/${encodeURIComponent(doc.id)}/pages`, {
      signal: controller.signal,
    })
      .then((value) => {
        if (controller.signal.aborted) return
        if (
          !Array.isArray(value) ||
          value.length !== doc.pages ||
          value.some(
            (size) =>
              !Number.isFinite(size.w) ||
              !Number.isFinite(size.h) ||
              size.w <= 0 ||
              size.h <= 0
          )
        ) {
          throw new Error("페이지 크기 정보가 올바르지 않습니다.")
        }
        setSizes(value)
      })
      .catch((reason: unknown) => {
        if (!controller.signal.aborted)
          setGeometryError(
            reason instanceof Error
              ? reason.message
              : "페이지 크기를 불러오지 못했습니다."
          )
      })
    return () => controller.abort()
  }, [doc.id, doc.pages, geometryAttempt])

  useLayoutEffect(() => {
    const node = scrollRef.current
    if (!node) return
    const measure = () =>
      setViewport((value) => {
        const width = node.clientWidth,
          height = node.clientHeight
        return value.width === width && value.height === height
          ? value
          : { ...value, width, height }
      })
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(node)
    return () => observer.disconnect()
  }, [mode])

  const publishMeta = useCallback(
    (docId: string, number: number, meta: PageMeta) => {
      if (number === activePage.current)
        callbacks.current.onPageMeta(docId, number, meta)
    },
    []
  )
  const lookup = useCallback((input: LookupInput) => {
    if (input.page !== activePage.current) {
      reportedPage.current = input.page
      callbacks.current.onPageChange(input.page)
    }
    callbacks.current.onLookup(input)
  }, [])

  const sampleViewport = useCallback(
    (report: boolean) => {
      const node = scrollRef.current
      if (!node || !layout.length) return
      const center = node.scrollTop + node.clientHeight / 2
      const number = pageAt(layout, center)
      anchor.current = {
        page: number,
        ratio: Math.max(
          0,
          Math.min(1, (center - layout[number].top) / layout[number].height)
        ),
      }
      setViewport((value) =>
        value.top === node.scrollTop ? value : { ...value, top: node.scrollTop }
      )
      if (
        report &&
        number !== activePage.current &&
        number !== reportedPage.current
      ) {
        reportedPage.current = number
        callbacks.current.onPageChange(number)
      }
    },
    [layout]
  )

  useLayoutEffect(() => {
    if (mode !== "continuous") {
      positioned.current = null
      return
    }
    const node = scrollRef.current
    if (!node || !viewport.width || !layout.length) return
    const previous = positioned.current
    const pageChanged = previous?.page !== page
    const ownReport = pageChanged && reportedPage.current === page
    if (!previous || (pageChanged && !ownReport)) {
      node.scrollTop = Math.max(
        0,
        layout[Math.min(page, layout.length - 1)].top - padding
      )
      programmaticTop.current = node.scrollTop
    } else if (
      previous.layout !== layout ||
      previous.height !== viewport.height
    ) {
      const saved = anchor.current
      const target = layout[Math.min(saved.page, layout.length - 1)]
      node.scrollTop = Math.max(
        0,
        target.top + target.height * saved.ratio - node.clientHeight / 2
      )
      programmaticTop.current = node.scrollTop
    }
    if (pageChanged) reportedPage.current = null
    positioned.current = { page, layout, height: viewport.height }
    sampleViewport(false)
  }, [mode, page, layout, viewport.width, viewport.height, sampleViewport])

  if (mode === "page")
    return (
      <PageSlot
        key={page}
        doc={doc}
        page={page}
        active
        cache={cache}
        zoom={zoom}
        lookups={lookups}
        onLookup={lookup}
        onPageMeta={publishMeta}
        flashWordIds={flashWordIds}
      />
    )

  const first = pageAt(layout, Math.max(0, viewport.top - viewport.height))
  const last = pageAt(layout, viewport.top + viewport.height * 2)
  return (
    <div
      ref={scrollRef}
      className="pdf-continuous"
      data-pdf-scroll
      tabIndex={0}
      aria-label="교안 연속 보기"
      onScroll={() => {
        const node = scrollRef.current
        if (!node || !positioned.current) return
        // A short slide can leave the viewport center on a later page after a
        // jump. Keep the requested page until the user actually scrolls again.
        const ownScroll =
          programmaticTop.current !== null &&
          Math.abs(node.scrollTop - programmaticTop.current) < 1
        if (!ownScroll) programmaticTop.current = null
        sampleViewport(!ownScroll)
      }}
    >
      {geometryError ? (
        <div className="pdf-page-message" role="alert">
          <span>{geometryError}</span>
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              setGeometryError("")
              setGeometryAttempt((value) => value + 1)
            }}
          >
            다시 시도
          </Button>
        </div>
      ) : !sizes.length || !viewport.width ? (
        <div className="pdf-page-message" role="status">
          <Skeleton className="h-3 w-32" />
          <span>교안 불러오는 중…</span>
        </div>
      ) : (
        <div className="pdf-stack" style={{ width }}>
          {layout.map((position, number) => (
            <div
              key={number}
              className="pdf-page-placeholder"
              data-pdf-page={number}
              style={{ height: position.height }}
              aria-label={`${number + 1}쪽`}
            >
              {number >= first && number <= last ? (
                <PageSlot
                  doc={doc}
                  page={number}
                  active={number === page}
                  cache={cache}
                  zoom={zoom}
                  embedded
                  lookups={lookups}
                  onLookup={lookup}
                  onPageMeta={publishMeta}
                  flashWordIds={flashWordIds}
                />
              ) : null}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
