import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react"
import { useVirtualizer } from "@tanstack/react-virtual"
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
const padding = 24
const gap = 24
const emptyLookups: Lookup[] = []
const emptyWordIds: number[] = []

const PageSlot = memo(function PageSlot({
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
    <div
      className={embedded ? "pdf-viewer-page is-embedded" : "pdf-viewer-page"}
    >
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
})

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
  const [viewport, setViewport] = useState({ width: 0, height: 0 })
  const scrollRef = useRef<HTMLDivElement>(null)
  const callbacks = useRef({ onPageChange, onPageMeta, onLookup })
  const activePage = useRef(page)
  const reportedPage = useRef<number | null>(null)
  const programmaticTop = useRef<number | null>(null)
  const anchor = useRef({ page, ratio: 0 })
  const positioned = useRef<{
    page: number
    width: number
    height: number
    sizes: PageSize[]
  } | null>(null)
  const width = Math.max(1, viewport.width - padding * 2) * (zoom || 1)
  const groupedLookups = useMemo(() => {
    const groups = new Map<number, Lookup[]>()
    for (const lookup of lookups) {
      if (lookup.doc_id !== doc.id) continue
      const rows = groups.get(lookup.page)
      if (rows) rows.push(lookup)
      else groups.set(lookup.page, [lookup])
    }
    return groups
  }, [lookups, doc.id])
  const flash = flashWordIds?.length ? flashWordIds : emptyWordIds
  const estimateSize = useCallback(
    (index: number) => (width * sizes[index].h) / sizes[index].w,
    [sizes, width]
  )
  // Measurement keys include geometry so zoom/resize invalidates estimates.
  // React keys below remain page numbers, preserving mounted page state.
  const getItemKey = useCallback(
    (index: number) => `${index}:${width}:${sizes[index].w}:${sizes[index].h}`,
    [sizes, width]
  )
  // Virtualizer owns mutable measurements; only scalar item data reaches memoized pages.
  // eslint-disable-next-line react-hooks/incompatible-library
  const virtualizer = useVirtualizer({
    count: sizes.length,
    getScrollElement: () => scrollRef.current,
    estimateSize,
    getItemKey,
    overscan: 2,
    paddingStart: padding,
    paddingEnd: padding,
    scrollPaddingStart: padding,
    gap,
    enabled: mode === "continuous" && viewport.width > 0 && sizes.length > 0,
    useFlushSync: false,
  })
  const virtualPages = virtualizer.getVirtualItems()
  const totalHeight = virtualizer.getTotalSize()

  useLayoutEffect(() => {
    // Notes below the page being read must not move it. Compensate only when
    // an already-passed page changes height above the viewport.
    virtualizer.shouldAdjustScrollPositionOnItemSizeChange = (
      item,
      _delta,
      instance
    ) => item.end <= (instance.scrollOffset ?? 0)
    return () => {
      virtualizer.shouldAdjustScrollPositionOnItemSizeChange = undefined
    }
  }, [virtualizer])

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
          : { width, height }
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
      if (!node) return
      const center = node.scrollTop + node.clientHeight / 2
      const item = virtualizer.getVirtualItemForOffset(center)
      if (!item) return
      anchor.current = {
        page: item.index,
        ratio: Math.max(0, Math.min(1, (center - item.start) / item.size)),
      }
      if (
        report &&
        item.index !== activePage.current &&
        item.index !== reportedPage.current
      ) {
        reportedPage.current = item.index
        callbacks.current.onPageChange(item.index)
      }
    },
    [virtualizer]
  )

  useLayoutEffect(() => {
    if (mode !== "continuous") {
      positioned.current = null
      return
    }
    const node = scrollRef.current
    if (!node || !viewport.width || !sizes.length) return
    const previous = positioned.current
    const pageChanged = previous?.page !== page
    const ownReport = pageChanged && reportedPage.current === page
    if (!previous || (pageChanged && !ownReport)) {
      virtualizer.scrollToIndex(page, { align: "start", behavior: "auto" })
      programmaticTop.current = node.scrollTop
    } else if (
      previous.width !== width ||
      previous.height !== viewport.height ||
      previous.sizes !== sizes
    ) {
      const saved = anchor.current
      const item =
        virtualizer.measurementsCache[Math.min(saved.page, sizes.length - 1)]
      if (item) {
        virtualizer.scrollToOffset(
          item.start + item.size * saved.ratio - node.clientHeight / 2
        )
        programmaticTop.current = node.scrollTop
      }
    }
    if (pageChanged) reportedPage.current = null
    positioned.current = { page, width, height: viewport.height, sizes }
    sampleViewport(false)
  }, [
    mode,
    page,
    sizes,
    width,
    viewport.width,
    viewport.height,
    virtualizer,
    sampleViewport,
  ])

  if (mode === "page")
    return (
      <PageSlot
        key={page}
        doc={doc}
        page={page}
        active
        cache={cache}
        zoom={zoom}
        lookups={groupedLookups.get(page) ?? emptyLookups}
        onLookup={lookup}
        onPageMeta={publishMeta}
        flashWordIds={flash}
      />
    )

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
        <div className="pdf-stack" style={{ width, height: totalHeight }}>
          {virtualPages.map((item) => (
            <div
              key={item.index}
              ref={virtualizer.measureElement}
              className="pdf-page-placeholder"
              data-index={item.index}
              data-pdf-page={item.index}
              style={{
                minHeight: estimateSize(item.index),
                transform: `translateY(${item.start}px)`,
              }}
              aria-label={`${item.index + 1}쪽`}
            >
              <PageSlot
                doc={doc}
                page={item.index}
                active={item.index === page}
                cache={cache}
                zoom={zoom}
                embedded
                lookups={groupedLookups.get(item.index) ?? emptyLookups}
                onLookup={lookup}
                onPageMeta={publishMeta}
                flashWordIds={item.index === page ? flash : emptyWordIds}
              />
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
