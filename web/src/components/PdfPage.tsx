import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react"
import { cn } from "cn"
import type { CSSProperties, KeyboardEvent, PointerEvent } from "react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import type { Doc, Lookup, LookupInput, PageMeta, Word } from "@/lib/types"
import "./pdf-page.css"

type Props = {
  doc: Doc
  page: number
  meta: PageMeta | null
  lookups: Lookup[]
  zoom: number
  onLookup: (input: LookupInput) => void
  flashWordIds?: number[]
  embedded?: boolean
}
type Gesture = {
  pointerId: number
  context: string
  meta: PageMeta
  start: number
  end: number
}
type Label = {
  key: string
  text: string
  style: CSSProperties
  center?: number
}
const emptyWordIds: number[] = []

function rasterScale(meta: PageMeta | null, width: number, pixelRatio: number) {
  if (!meta || !width) return 0
  const desired = (width / meta.w) * pixelRatio
  return [1, 1.5, 2, 3, 4].find((scale) => scale >= desired) ?? 4
}

function inkBox(word: Word) {
  return word.ink ?? word
}

function annotationLayout(meta: PageMeta, row: Word[]) {
  const boxes = row.map(inkBox)
  const left = Math.min(...boxes.map((box) => box.x0)),
    right = Math.max(...boxes.map((box) => box.x1))
  const y0 = Math.min(...boxes.map((box) => box.y0)),
    y1 = Math.max(...boxes.map((box) => box.y1))
  const gap = Math.min(meta.h - y1, ...row.map((word) => word.gap ?? 99))
  // Use PDF units so zoom changes size, never the annotation's placement policy.
  const size = Math.min(7.5, (y1 - y0) * 0.5, (gap - 2) / 1.1)
  return {
    mode: size >= 4.5 ? "below" : "note",
    center: (left + right) / 2,
    top: y1 + 1.5,
    size,
  }
}

function centerAnnotation(
  node: HTMLSpanElement | null,
  center: number,
  pageWidth: number,
  padding: number
) {
  if (!node) return
  const position = () => {
    const half = node.getBoundingClientRect().width / 2
    node.style.left = `${Math.max(half + padding, Math.min(pageWidth - half - padding, center))}px`
  }
  const observer = new ResizeObserver(position)
  observer.observe(node)
  position()
  return () => observer.disconnect()
}

const AnnotationLabel = memo(function AnnotationLabel({
  label,
  pageWidth,
  padding,
}: {
  label: Label
  pageWidth: number
  padding: number
}) {
  const positionRef = useCallback(
    (node: HTMLSpanElement | null) => {
      if (label.center !== undefined)
        return centerAnnotation(node, label.center, pageWidth, padding)
    },
    [label.center, pageWidth, padding]
  )
  return (
    <span
      className="pdf-annotation"
      style={label.style}
      title={label.text}
      ref={positionRef}
    >
      {label.text}
    </span>
  )
})

function selectionInput(
  meta: PageMeta,
  page: number,
  start: number,
  end: number,
  alt: boolean
): LookupInput | null {
  if (
    ![start, end].every(
      (id) => Number.isInteger(id) && id >= 0 && id < meta.words.length
    )
  )
    return null
  let ids = Array.from(
    { length: Math.abs(end - start) + 1 },
    (_, i) => Math.min(start, end) + i
  )
  let kind: LookupInput["kind"] = ids.length <= 2 ? "word" : "sentence"
  const word = meta.words[start]
  if (start === end && alt && word.s !== undefined && meta.sentences[word.s]) {
    ids = meta.sentences[word.s].w.filter(
      (id) => id >= 0 && id < meta.words.length
    )
    kind = "sentence"
  } else if (
    start === end &&
    word.join !== undefined &&
    meta.words[word.join]
  ) {
    ids.push(word.join)
  }
  return ids.length
    ? {
        page,
        kind,
        text: ids.map((id) => meta.words[id].t).join(" "),
        word_ids: ids,
      }
    : null
}

export const PdfPage = memo(function PdfPage({
  doc,
  page,
  meta,
  lookups,
  zoom,
  onLookup,
  flashWordIds = emptyWordIds,
  embedded = false,
}: Props) {
  const canvasRef = useRef<HTMLDivElement>(null)
  const imageRef = useRef<HTMLImageElement>(null)
  const overlayRef = useRef<HTMLDivElement>(null)
  const gesture = useRef<Gesture | null>(null)
  const [canvasWidth, setCanvasWidth] = useState(0)
  const [imageSize, setImageSize] = useState({ width: 0, height: 0 })
  const [loadedSource, setLoadedSource] = useState("")
  const [failedSource, setFailedSource] = useState("")
  const [imageAttempt, setImageAttempt] = useState(0)
  const [pixelRatio, setPixelRatio] = useState(
    () => window.devicePixelRatio || 1
  )
  const [selection, setSelection] = useState<{
    context: string
    source: string
    ids: number[]
  } | null>(null)
  const context = `${doc.id}:${page}`
  const scale = rasterScale(
    meta,
    canvasWidth * (embedded ? 1 : zoom || 1),
    pixelRatio
  )
  const source = scale
    ? `/api/docs/${encodeURIComponent(doc.id)}/page/${page}.png?scale=${scale}${imageAttempt ? `&retry=${imageAttempt}` : ""}`
    : ""

  useEffect(() => {
    const update = () => setPixelRatio(window.devicePixelRatio || 1)
    const query = window.matchMedia(`(resolution: ${pixelRatio}dppx)`)
    query.addEventListener("change", update)
    window.addEventListener("resize", update)
    return () => {
      query.removeEventListener("change", update)
      window.removeEventListener("resize", update)
    }
  }, [pixelRatio])
  const ready =
    !!meta &&
    meta.w > 0 &&
    meta.h > 0 &&
    loadedSource === source &&
    imageSize.width > 0 &&
    imageSize.height > 0

  useEffect(() => {
    const canvas = canvasRef.current,
      image = imageRef.current
    if (!canvas || !image) return
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        if (entry.target === canvas) setCanvasWidth(entry.contentRect.width)
        if (entry.target === image)
          setImageSize((size) =>
            size.width === entry.contentRect.width &&
            size.height === entry.contentRect.height
              ? size
              : {
                  width: entry.contentRect.width,
                  height: entry.contentRect.height,
                }
          )
      }
    })
    observer.observe(canvas)
    observer.observe(image)
    return () => observer.disconnect()
  }, [source])

  useEffect(
    () => () => {
      gesture.current = null
    },
    [context, source]
  )

  function wordAt(x: number, y: number) {
    const target = document
      .elementFromPoint(x, y)
      ?.closest<HTMLElement>("[data-pdf-word]")
    return target && overlayRef.current?.contains(target)
      ? Number(target.dataset.pdfWord)
      : null
  }
  function clearGesture(event: PointerEvent<HTMLDivElement>) {
    if (gesture.current?.pointerId !== event.pointerId) return
    gesture.current = null
    setSelection(null)
    if (event.currentTarget.hasPointerCapture(event.pointerId))
      event.currentTarget.releasePointerCapture(event.pointerId)
  }
  function startGesture(event: PointerEvent<HTMLDivElement>) {
    if (
      !ready ||
      !meta ||
      event.button !== 0 ||
      !event.isPrimary ||
      gesture.current
    )
      return
    const target = (event.target as Element).closest<HTMLElement>(
      "[data-pdf-word]"
    )
    if (!target || !event.currentTarget.contains(target)) return
    const id = Number(target.dataset.pdfWord)
    event.preventDefault()
    target.focus({ preventScroll: true })
    gesture.current = {
      pointerId: event.pointerId,
      context,
      meta,
      start: id,
      end: id,
    }
    setSelection({ context, source, ids: [id] })
    event.currentTarget.setPointerCapture(event.pointerId)
  }
  function moveGesture(event: PointerEvent<HTMLDivElement>) {
    const active = gesture.current
    if (
      !active ||
      active.pointerId !== event.pointerId ||
      active.context !== context ||
      active.meta !== meta
    )
      return
    const id = wordAt(event.clientX, event.clientY)
    if (id === null || id === active.end) return
    active.end = id
    setSelection({
      context,
      source,
      ids: Array.from(
        { length: Math.abs(id - active.start) + 1 },
        (_, i) => Math.min(id, active.start) + i
      ),
    })
  }
  function finishGesture(event: PointerEvent<HTMLDivElement>) {
    const active = gesture.current
    if (!active || active.pointerId !== event.pointerId) return
    clearGesture(event)
    if (!ready || active.context !== context || active.meta !== meta) return
    const releasedOver = document.elementFromPoint(event.clientX, event.clientY)
    if (!releasedOver || !event.currentTarget.contains(releasedOver)) return
    const input = selectionInput(
      active.meta,
      page,
      active.start,
      wordAt(event.clientX, event.clientY) ?? active.end,
      event.altKey
    )
    if (input) onLookup(input)
  }
  function activateWord(event: KeyboardEvent<HTMLButtonElement>, id: number) {
    if (!ready || !meta || event.repeat || !["Enter", " "].includes(event.key))
      return
    event.preventDefault()
    const input = selectionInput(meta, page, id, id, event.altKey)
    if (input) onLookup(input)
  }

  const sx = meta ? imageSize.width / meta.w : 0,
    sy = meta ? imageSize.height / meta.h : 0
  const { pending, sentences, errors, lines, labels, notes } = useMemo(() => {
    const pending = new Set<number>(),
      sentences = new Set<number>(),
      errors = new Set<number>()
    const lines: { key: string; style: CSSProperties }[] = [],
      labels: Label[] = []
    const notes: { id: number; text: string; meaning: string }[] = []
    for (const lookup of lookups.filter(
      (item) => item.doc_id === doc.id && item.page === page
    )) {
      for (const id of lookup.word_ids) {
        if (lookup.status === "pending") pending.add(id)
        else if (lookup.status === "error") errors.add(id)
        else if (lookup.kind === "sentence") sentences.add(id)
      }
      if (
        !meta ||
        lookup.kind !== "word" ||
        lookup.status !== "done" ||
        !lookup.result?.meaning
      )
        continue
      const words = lookup.word_ids
        .map((id) => meta.words[id])
        .filter((word): word is Word => !!word)
      if (!words.length) continue
      const first = words.reduce((a, b) =>
        inkBox(b).y0 < inkBox(a).y0 ||
        (inkBox(b).y0 === inkBox(a).y0 && inkBox(b).x0 < inkBox(a).x0)
          ? b
          : a
      )
      const row = words.filter(
        (word) => word.b === first.b && word.l === first.l
      )
      const layout = annotationLayout(meta, row)
      if (layout.mode === "note")
        notes.push({
          id: lookup.id,
          text: lookup.text,
          meaning: lookup.result.meaning,
        })
      if (!ready) continue
      const rows = new Map<number, Word[]>()
      for (const word of words) {
        const y = Math.round(inkBox(word).y1)
        rows.set(y, [...(rows.get(y) || []), word])
      }
      for (const [y, row] of rows) {
        const left = Math.min(...row.map((word) => inkBox(word).x0)),
          right = Math.max(...row.map((word) => inkBox(word).x1))
        lines.push({
          key: `${lookup.id}:${y}`,
          style: {
            left: left * sx,
            top: (Math.max(...row.map((word) => inkBox(word).y1)) + 0.5) * sy,
            width: (right - left) * sx,
          },
        })
      }
      if (layout.mode === "below")
        labels.push({
          key: `word:${lookup.id}`,
          text: lookup.result.meaning,
          center: layout.center * sx,
          style: {
            left: layout.center * sx,
            top: layout.top * sy,
            fontSize: layout.size * sy,
            lineHeight: 1.1,
            maxWidth: Math.max(0, meta.w - 4) * sx,
            transform: "translateX(-50%)",
          },
        })
    }

    return { pending, sentences, errors, lines, labels, notes }
  }, [lookups, doc.id, page, ready, meta, sx, sy])
  const selected = new Set(
    selection?.context === context && selection.source === source
      ? selection.ids
      : []
  )
  const flashed = new Set(flashWordIds)

  return (
    <div
      ref={canvasRef}
      className={cn("pdf-canvas", embedded && "is-embedded")}
      aria-label="교안 페이지"
      aria-busy={!ready && (!source || failedSource !== source)}
    >
      <div
        className="pdf-sheet"
        data-loading={!ready || undefined}
        style={{
          width: embedded
            ? "100%"
            : canvasWidth
              ? canvasWidth * (zoom || 1)
              : "100%",
          aspectRatio: meta ? `${meta.w} / ${meta.h}` : undefined,
        }}
      >
        <img
          key={source}
          ref={imageRef}
          src={source || undefined}
          alt={`${doc.name} ${page + 1}쪽`}
          draggable={false}
          onLoad={() => setLoadedSource(source)}
          onError={() => setFailedSource(source)}
        />
        {!ready && (
          <div className="pdf-loading">
            {(!source || failedSource !== source) && (
              <Skeleton className="h-3 w-32" />
            )}
            <span role={source && failedSource === source ? "alert" : "status"}>
              {source && failedSource === source
                ? "페이지를 불러오지 못했습니다."
                : "교안 불러오는 중…"}
            </span>
            {source && failedSource === source && (
              <Button
                variant="outline"
                size="sm"
                onClick={() => setImageAttempt((value) => value + 1)}
              >
                다시 시도
              </Button>
            )}
          </div>
        )}
        {ready && meta && (
          <div
            ref={overlayRef}
            className="pdf-overlay"
            onPointerDown={startGesture}
            onPointerMove={moveGesture}
            onPointerUp={finishGesture}
            onPointerCancel={clearGesture}
            onLostPointerCapture={clearGesture}
          >
            {meta.words.map((word) => (
              <button
                key={word.i}
                type="button"
                data-pdf-word={word.i}
                className={cn(
                  "pdf-word",
                  sentences.has(word.i) && "is-sentence",
                  pending.has(word.i) && "is-pending",
                  errors.has(word.i) && "is-error",
                  selected.has(word.i) && "is-selected",
                  flashed.has(word.i) && "is-flashed"
                )}
                style={{
                  left: word.x0 * sx,
                  top: word.y0 * sy,
                  width: (word.x1 - word.x0) * sx,
                  height: (word.y1 - word.y0) * sy,
                }}
                aria-label={`${word.t} 뜻 보기`}
                title={word.t}
                onKeyDown={(event) => activateWord(event, word.i)}
              />
            ))}
            {lines.map((line) => (
              <span
                key={line.key}
                className="pdf-underline"
                style={line.style}
                aria-hidden="true"
              />
            ))}
            {labels.map((label) => (
              <AnnotationLabel
                key={label.key}
                label={label}
                pageWidth={imageSize.width}
                padding={2 * sx}
              />
            ))}
          </div>
        )}
      </div>
      {notes.length > 0 && (
        <aside
          className="pdf-word-notes"
          aria-label="단어 뜻"
          style={{
            width: embedded
              ? "100%"
              : canvasWidth
                ? canvasWidth * (zoom || 1)
                : "100%",
          }}
        >
          <p className="mb-2 text-xs font-semibold">단어 뜻</p>
          <dl className="space-y-1.5 text-sm">
            {notes.map((note) => (
              <div key={note.id} className="flex flex-wrap gap-x-2">
                <dt className="font-medium">{note.text}</dt>
                <dd>{note.meaning}</dd>
              </div>
            ))}
          </dl>
        </aside>
      )}
    </div>
  )
})
