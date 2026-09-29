import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react"
import type { KeyboardEvent, MouseEvent } from "react"
import SelectionArea from "@viselect/vanilla"
import type { SelectionEvent } from "@viselect/vanilla"

type Modifiers = { metaKey?: boolean; ctrlKey?: boolean; shiftKey?: boolean }
type Gesture = {
  base: string[]
  anchor: string | null
  additive: boolean
  dragged: boolean
}
const interactive =
  '[data-library-item],button,a,input,select,textarea,[contenteditable]:not([contenteditable="false"]),[role="button"],[role="dialog"],[role="menu"],[role="menuitem"],[data-library-selection-ignore],[data-selection-ignore]'
const editable =
  'input,textarea,select,[contenteditable]:not([contenteditable="false"]),[role="textbox"],[role="dialog"],[role="menu"]'

function itemSelection(
  ids: string[],
  selected: string[],
  anchor: string | null,
  id: string,
  modifiers: Modifiers
): string[] {
  if (!ids.includes(id)) return selected
  const additive = modifiers.metaKey || modifiers.ctrlKey
  if (modifiers.shiftKey) {
    const start = Math.max(0, ids.indexOf(anchor ?? id)),
      end = ids.indexOf(id)
    const range = ids.slice(Math.min(start, end), Math.max(start, end) + 1)
    const chosen = new Set(additive ? [...selected, ...range] : range)
    return ids.filter((key) => chosen.has(key))
  }
  if (!additive) return [id]
  const chosen = new Set(selected)
  if (chosen.has(id)) chosen.delete(id)
  else chosen.add(id)
  return ids.filter((key) => chosen.has(key))
}

export function useLibrarySelection({
  itemIds,
  scopeKey,
}: {
  itemIds: string[]
  scopeKey: string
}) {
  const signature = JSON.stringify([scopeKey, itemIds])
  const ids = useMemo(() => JSON.parse(signature)[1] as string[], [signature])
  const selectionId = useId()
  const containerRef = useRef<HTMLDivElement>(null)
  const area = useRef<SelectionArea | null>(null)
  const gesture = useRef<Gesture | null>(null)
  const anchor = useRef<string | null>(null)
  const current = useRef({ scopeKey, ids: [] as string[] })
  const suppressClick = useRef(false)
  const suppressionTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const [selection, setSelection] = useState({
    scopeKey,
    signature,
    ids: [] as string[],
  })
  const selectedIds =
    selection.scopeKey === scopeKey
      ? selection.ids.filter((id) => ids.includes(id))
      : []
  if (selection.signature !== signature)
    setSelection({ scopeKey, signature, ids: selectedIds })

  const commit = useCallback(
    (values: string[], nextAnchor: string | null) => {
      const chosen = new Set(values),
        next = ids.filter((id) => chosen.has(id))
      current.current = { scopeKey, ids: next }
      anchor.current =
        nextAnchor && next.includes(nextAnchor) ? nextAnchor : (next[0] ?? null)
      setSelection({ scopeKey, signature, ids: next })
      return next
    },
    [ids, scopeKey, signature]
  )
  const syncLibrary = useCallback((values: string[]) => {
    if (!area.current || !containerRef.current) return
    const chosen = new Set(values)
    const elements = Array.from(
      containerRef.current.querySelectorAll<HTMLElement>("[data-library-item]")
    ).filter((element) => chosen.has(element.dataset.libraryItem!))
    area.current.clearSelection(true, true)
    area.current.select(elements, true)
  }, [])
  const suppressNextClick = useCallback(() => {
    suppressClick.current = true
    if (suppressionTimer.current !== null)
      clearTimeout(suppressionTimer.current)
    suppressionTimer.current = setTimeout(() => {
      suppressClick.current = false
    }, 0)
  }, [])
  const cancelGesture = useCallback(() => {
    const active = gesture.current
    if (!active) return false
    gesture.current = null
    area.current?.cancel()
    syncLibrary(commit(active.base, active.anchor))
    if (active.dragged) suppressNextClick()
    return true
  }, [commit, syncLibrary, suppressNextClick])

  useEffect(() => {
    const node = containerRef.current
    if (!node) return
    const previousId = node.id
    if (!node.id) node.id = selectionId
    const boundary =
      node.closest<HTMLElement>('[data-slot="scroll-area-viewport"]') ?? node
    const instance = new SelectionArea({
      document: node.ownerDocument,
      selectionAreaClass: "library-selection-area",
      startAreas: [node],
      boundaries: [boundary],
      selectables: [`#${CSS.escape(node.id)} [data-library-item]`],
      features: { touch: false, singleTap: { allow: false }, range: false },
      behaviour: {
        overlap: "keep",
        startThreshold: { x: 4, y: 4 },
        scrolling: { startScrollMargins: { x: 16, y: 32 } },
      },
    })
    area.current = instance
    const retained =
      current.current.scopeKey === scopeKey
        ? current.current.ids.filter((id) => ids.includes(id))
        : []
    current.current = { scopeKey, ids: retained }
    if (!anchor.current || !retained.includes(anchor.current))
      anchor.current = retained[0] ?? null
    syncLibrary(retained)
    instance.on("beforestart", ({ event }) => {
      if (
        !event ||
        !("button" in event) ||
        event.button !== 0 ||
        !(event.target instanceof Element) ||
        !node.contains(event.target) ||
        event.target.closest(interactive)
      )
        return false
      if (gesture.current?.dragged) return false
      gesture.current = {
        base: [...current.current.ids],
        anchor: anchor.current,
        additive: !!(event.metaKey || event.ctrlKey || event.shiftKey),
        dragged: false,
      }
      suppressClick.current = false
      syncLibrary(current.current.ids)
    })
    instance.on("beforedrag", () => {
      node.focus({ preventScroll: true })
    })
    instance.on("start", () => {
      const active = gesture.current
      if (!active) return
      active.dragged = true
      if (!active.additive) {
        instance.clearSelection(true, true)
        commit([], null)
      }
    })
    const publish = ({ store }: SelectionEvent) => {
      const active = gesture.current
      if (!active?.dragged) return
      const values = [...store.stored, ...store.selected].map(
        (element) => element.getAttribute("data-library-item") || ""
      )
      commit(values, active.additive ? active.anchor : null)
    }
    instance.on("move", publish)
    instance.on("stop", (event) => {
      if (!gesture.current?.dragged) return
      publish(event)
      gesture.current = null
      suppressNextClick()
    })
    const cancel = () => {
      cancelGesture()
    }
    const view = node.ownerDocument.defaultView ?? window
    view.addEventListener("blur", cancel)
    node.ownerDocument.addEventListener("pointercancel", cancel)
    return () => {
      gesture.current = null
      instance.destroy()
      if (area.current === instance) area.current = null
      view.removeEventListener("blur", cancel)
      node.ownerDocument.removeEventListener("pointercancel", cancel)
      if (suppressionTimer.current !== null)
        clearTimeout(suppressionTimer.current)
      suppressClick.current = false
      if (!previousId && node.id === selectionId) node.removeAttribute("id")
    }
  }, [
    ids,
    scopeKey,
    selectionId,
    commit,
    syncLibrary,
    suppressNextClick,
    cancelGesture,
  ])

  function setSelectedIds(values: string[], nextAnchor = anchor.current) {
    cancelGesture()
    syncLibrary(commit(values, nextAnchor))
  }
  function clearSelection() {
    setSelectedIds([], null)
  }
  function selectItem(id: string, modifiers: Modifiers = {}) {
    if (!ids.includes(id)) return
    cancelGesture()
    const before =
      current.current.scopeKey === scopeKey ? current.current.ids : []
    const previousAnchor = anchor.current ?? before[0] ?? null
    const next = itemSelection(ids, before, previousAnchor, id, modifiers)
    syncLibrary(
      commit(next, modifiers.shiftKey && previousAnchor ? previousAnchor : id)
    )
  }
  function onClickCapture(event: MouseEvent<HTMLDivElement>) {
    if (suppressClick.current) {
      suppressClick.current = false
      event.preventDefault()
      event.stopPropagation()
      return
    }
    if (
      event.button === 0 &&
      event.target instanceof Element &&
      !event.target.closest(interactive)
    ) {
      clearSelection()
      containerRef.current?.focus({ preventScroll: true })
    }
  }
  function onKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (!(event.target instanceof Element) || event.target.closest(editable))
      return
    if (event.key === "Escape") {
      if (!cancelGesture()) clearSelection()
      event.preventDefault()
      event.stopPropagation()
    } else if (
      (event.metaKey || event.ctrlKey) &&
      event.key.toLowerCase() === "a"
    ) {
      setSelectedIds(ids)
      event.preventDefault()
      event.stopPropagation()
    }
  }
  return {
    selectedIds,
    setSelectedIds,
    clearSelection,
    selectItem,
    isSelected: (id: string) => selectedIds.includes(id),
    containerRef,
    onClickCapture,
    onKeyDown,
  }
}
