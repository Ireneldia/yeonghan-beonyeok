import { useMemo, useState, type DragEvent, type MouseEvent } from "react"
import {
  Check,
  ChevronRight,
  Copy,
  FileText,
  FolderOpen,
  FolderPlus,
  LayoutGrid,
  List,
  FolderInput,
  Plus,
  RefreshCw,
  Search,
  Trash2,
  X,
} from "lucide-react"
import { toast } from "sonner"
import type { Doc, Folder } from "@/lib/types"
import {
  DOCUMENT_DRAG_TYPE,
  splitSelection,
  type LibrarySelection,
} from "@/lib/library"
import { useLibrarySelection } from "@/hooks/useLibrarySelection"
import { LibraryItemMenu } from "@/components/LibraryItemMenu"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Skeleton } from "@/components/ui/skeleton"

type Item = {
  key: string
  name: string
  created: number
  doc?: Doc
  folder?: Folder
}
type Props = {
  docs: Doc[]
  folders: Folder[]
  currentFolder: Folder | null
  query: string
  onQueryChange: (query: string) => void
  loading: boolean
  busy: boolean
  dropTarget: string | null
  onUpload: () => void
  onCreateFolder: () => void
  onRefresh: () => void
  onCopySummary: () => void
  onRenameDoc: (doc: Doc) => void
  onRenameFolder: (folder: Folder) => void
  onMove: (docIds: string[]) => void
  onDelete: (selection: LibrarySelection) => void
  onDragDocuments: (ids: string[]) => void
  onDragEnd: () => void
}

export function DocumentLibrary(props: Props) {
  const { docs, folders, currentFolder, query, loading, busy } = props
  const [view, setView] = useState<"grid" | "list">(() => {
    try {
      return localStorage.getItem("yeonghan-library-view") === "list"
        ? "list"
        : "grid"
    } catch {
      return "grid"
    }
  })
  function changeView(next: "grid" | "list") {
    setView(next)
    try {
      localStorage.setItem("yeonghan-library-view", next)
    } catch {
      /* 저장을 막은 브라우저에서도 화면 전환은 가능하다. */
    }
  }
  const [sort, setSort] = useState<"name" | "recent">("name")
  const items = useMemo<Item[]>(() => {
    const compare = (a: Item, b: Item) =>
      sort === "recent"
        ? b.created - a.created
        : a.name.localeCompare(b.name, "ko", { numeric: true })
    return [
      ...folders
        .map((folder) => ({
          key: `folder:${folder.id}`,
          name: folder.name,
          created: folder.created,
          folder,
        }))
        .sort(compare),
      ...docs
        .map((doc) => ({
          key: `doc:${doc.id}`,
          name: doc.name,
          created: doc.created,
          doc,
        }))
        .sort(compare),
    ]
  }, [docs, folders, sort])
  const {
    selectedIds,
    setSelectedIds,
    clearSelection,
    selectItem,
    isSelected,
    containerRef,
    onClickCapture,
    onKeyDown,
  } = useLibrarySelection({
    itemIds: items.map((item) => item.key),
    scopeKey: `${currentFolder?.id ?? "root"}:${query}`,
  })
  const selected = useMemo(() => splitSelection(selectedIds), [selectedIds])
  const count = selectedIds.length
  const movable = selected.docIds.length > 0 && !selected.folderIds.length
  function chosen(item: Item) {
    return isSelected(item.key) ? selectedIds : [item.key]
  }
  function selectForMenu(item: Item) {
    if (!isSelected(item.key)) setSelectedIds([item.key])
  }
  function open(item: Item) {
    window.location.assign(
      item.doc ? `#/doc/${item.doc.id}/1` : `#/folder/${item.folder!.id}`
    )
  }
  function clickItem(event: MouseEvent, item: Item) {
    if (event.metaKey || event.ctrlKey || event.shiftKey) {
      event.preventDefault()
      selectItem(item.key, event)
    }
  }
  function startDrag(event: DragEvent, item: Item) {
    if (
      busy ||
      !item.doc ||
      (event.target instanceof Element &&
        event.target.closest("button,[data-library-selection-ignore]"))
    ) {
      event.preventDefault()
      return
    }
    const keys = chosen(item),
      value = splitSelection(keys)
    if (value.folderIds.length) {
      event.preventDefault()
      toast("교안만 선택하면 폴더로 옮길 수 있어요.")
      return
    }
    setSelectedIds(keys)
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData(DOCUMENT_DRAG_TYPE, JSON.stringify(value.docIds))
    props.onDragDocuments(value.docIds)
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col bg-background">
      <div className="flex shrink-0 flex-wrap items-center justify-between gap-3 border-b px-5 py-4">
        <nav
          aria-label="교안 경로"
          className="flex min-w-0 items-center gap-2 text-sm"
        >
          <a
            href="#/"
            data-folder-drop=""
            className={`rounded-md px-2 py-1 font-semibold hover:bg-accent ${props.dropTarget === "root" ? "bg-primary/10 ring-2 ring-primary" : ""}`}
          >
            내 교안
          </a>
          {currentFolder && (
            <>
              <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
              <span className="max-w-72 truncate" aria-current="page">
                {currentFolder.name}
              </span>
            </>
          )}
        </nav>
        <div className="flex items-center gap-2">
          {!currentFolder && (
            <Button
              variant="outline"
              size="sm"
              disabled={busy}
              onClick={props.onCreateFolder}
            >
              <FolderPlus />새 폴더
            </Button>
          )}
          <Button size="sm" disabled={busy} onClick={props.onUpload}>
            <Plus />
            교안 추가
          </Button>
        </div>
      </div>
      <div className="flex shrink-0 flex-wrap items-center gap-2 border-b px-5 py-3">
        <div className="relative min-w-40 flex-1 sm:max-w-72">
          <Search className="pointer-events-none absolute top-2.5 left-3 size-4 text-muted-foreground" />
          <Input
            aria-label="교안 검색"
            placeholder="이름으로 검색"
            value={query}
            onChange={(event) => props.onQueryChange(event.target.value)}
            className="h-9 pl-9"
          />
        </div>
        <div className="ml-auto flex items-center gap-1">
          <Select
            value={sort}
            onValueChange={(value) => {
              if (value) setSort(value as "name" | "recent")
            }}
          >
            <SelectTrigger aria-label="정렬" className="w-28">
              <SelectValue>
                {sort === "name" ? "이름순" : "최근 추가순"}
              </SelectValue>
            </SelectTrigger>
            <SelectContent alignItemWithTrigger={false}>
              <SelectItem value="name">이름순</SelectItem>
              <SelectItem value="recent">최근 추가순</SelectItem>
            </SelectContent>
          </Select>
          <Button
            variant={view === "grid" ? "secondary" : "ghost"}
            size="icon-sm"
            aria-label="격자 보기"
            aria-pressed={view === "grid"}
            onClick={() => changeView("grid")}
          >
            <LayoutGrid />
          </Button>
          <Button
            variant={view === "list" ? "secondary" : "ghost"}
            size="icon-sm"
            aria-label="목록 보기"
            aria-pressed={view === "list"}
            onClick={() => changeView("list")}
          >
            <List />
          </Button>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="목록 새로고침"
            onClick={props.onRefresh}
          >
            <RefreshCw className={loading ? "animate-spin" : ""} />
          </Button>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="요약 프롬프트 복사"
            onClick={props.onCopySummary}
          >
            <Copy />
          </Button>
        </div>
      </div>
      <div
        className="flex min-h-11 shrink-0 items-center gap-2 border-b bg-muted/20 px-5 text-xs"
        aria-live="polite"
      >
        <span className="mr-auto text-muted-foreground">
          {count ? `${count}개 선택됨` : `${items.length}개 항목`}
        </span>
        {count > 0 && (
          <>
            <Button
              variant="ghost"
              size="sm"
              disabled={busy || !movable}
              onClick={() => props.onMove(selected.docIds)}
            >
              <FolderInput />
              이동
            </Button>
            <Button
              variant="ghost"
              size="sm"
              disabled={busy}
              onClick={() => props.onDelete(selected)}
            >
              <Trash2 />
              삭제
            </Button>
            <Button
              variant="ghost"
              size="icon-xs"
              aria-label="선택 해제"
              onClick={clearSelection}
            >
              <X />
            </Button>
          </>
        )}
      </div>
      <ScrollArea className="min-h-0 flex-1">
        <div
          ref={containerRef}
          role="group"
          aria-label="교안 파일 목록"
          tabIndex={0}
          className="relative min-h-full p-5 outline-none select-none focus-visible:outline-1 focus-visible:-outline-offset-2 focus-visible:outline-border"
          onClickCapture={onClickCapture}
          onKeyDown={(event) => {
            onKeyDown(event)
            if (
              event.defaultPrevented ||
              busy ||
              (event.target instanceof Element &&
                event.target.closest(
                  "input,textarea,[role=menu],[role=dialog]"
                ))
            )
              return
            if (
              (event.key === "Delete" || event.key === "Backspace") &&
              count
            ) {
              event.preventDefault()
              props.onDelete(selected)
            }
            if (
              event.key === "Enter" &&
              event.target === event.currentTarget &&
              count === 1
            ) {
              event.preventDefault()
              open(items.find((item) => item.key === selectedIds[0])!)
            }
          }}
        >
          {loading ? (
            <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
              {[1, 2, 3, 4].map((i) => (
                <Skeleton key={i} className="h-36 rounded-xl" />
              ))}
            </div>
          ) : (
            <div
              className={
                view === "grid"
                  ? "grid grid-cols-2 items-start gap-3 md:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5"
                  : "space-y-1"
              }
            >
              {items.map((item) => {
                const itemSelected = isSelected(item.key),
                  keys = itemSelected ? selectedIds : [item.key],
                  itemSelection = itemSelected ? selected : splitSelection(keys)
                const highlight =
                  item.folder && props.dropTarget === item.folder.id
                return (
                  <LibraryItemMenu
                    key={item.key}
                    view={view}
                    dropFolderId={item.folder?.id}
                    label={item.name}
                    selectionCount={keys.length}
                    disabled={busy}
                    onSelect={() => selectForMenu(item)}
                    onOpen={() => open(item)}
                    onRename={() =>
                      item.doc
                        ? props.onRenameDoc(item.doc)
                        : props.onRenameFolder(item.folder!)
                    }
                    onMove={
                      !itemSelection.folderIds.length
                        ? () => props.onMove(itemSelection.docIds)
                        : undefined
                    }
                    onDelete={() => props.onDelete(itemSelection)}
                  >
                    <div
                      data-library-item={item.key}
                      data-folder-drop={item.folder?.id}
                      data-selected={itemSelected || undefined}
                      draggable={!!item.doc && !busy}
                      onDragStart={(event) => startDrag(event, item)}
                      onDragEnd={props.onDragEnd}
                      className={`group relative rounded-xl border transition-colors ${itemSelected ? "border-primary/50 bg-primary/10 ring-1 ring-primary/35" : "border-transparent hover:bg-muted/60"} ${highlight ? "border-primary bg-primary/15 ring-2 ring-primary" : ""}`}
                    >
                      <Button
                        variant={itemSelected ? "default" : "outline"}
                        size="icon-xs"
                        role="checkbox"
                        aria-checked={itemSelected}
                        aria-label={`${item.name} 선택`}
                        data-library-selection-ignore=""
                        disabled={busy}
                        className={`absolute left-2 z-10 size-5 rounded-md ${view === "list" ? "inset-y-0 my-auto" : "top-2"} ${itemSelected ? "" : "opacity-0 group-hover:opacity-100 focus-visible:opacity-100 max-sm:opacity-100"}`}
                        onClick={(event) => {
                          event.stopPropagation()
                          selectItem(item.key, {
                            ...event,
                            ctrlKey: !event.shiftKey,
                          })
                        }}
                      >
                        {itemSelected && <Check className="size-3.5" />}
                      </Button>
                      <a
                        href={
                          item.doc
                            ? `#/doc/${item.doc.id}/1`
                            : `#/folder/${item.folder!.id}`
                        }
                        draggable={false}
                        onClick={(event) => clickItem(event, item)}
                        className={`rounded-xl outline-none focus-visible:ring-2 focus-visible:ring-ring ${view === "grid" ? "flex min-h-40 flex-col items-center px-4 pt-8 pb-4 text-center" : "flex min-h-16 items-center gap-4 py-3 pr-10 pl-10"}`}
                      >
                        {item.folder ? (
                          <FolderOpen
                            className={`shrink-0 text-primary ${view === "grid" ? "mb-4 size-12" : "size-7"}`}
                          />
                        ) : (
                          <FileText
                            className={`shrink-0 text-muted-foreground ${view === "grid" ? "mb-4 size-12" : "size-7"}`}
                          />
                        )}
                        <div
                          className={`min-w-0 ${view === "list" ? "flex-1" : "w-full"}`}
                        >
                          <h2
                            className={`${view === "grid" ? "line-clamp-2 min-h-10" : "truncate"} text-sm leading-5 font-medium break-words`}
                          >
                            {item.name}
                          </h2>
                          <p className="mt-1 text-xs text-muted-foreground">
                            {item.folder
                              ? `교안 ${item.folder.doc_count}개`
                              : `PDF · ${item.doc!.pages}쪽`}
                          </p>
                        </div>
                        {view === "list" && (
                          <span className="hidden shrink-0 text-xs text-muted-foreground sm:block">
                            {new Date(item.created * 1000).toLocaleDateString(
                              "ko-KR"
                            )}
                          </span>
                        )}
                      </a>
                    </div>
                  </LibraryItemMenu>
                )
              })}
            </div>
          )}
          {!loading && !items.length && (
            <div className="pointer-events-none flex min-h-64 flex-col items-center justify-center gap-3 text-sm text-muted-foreground">
              <FolderOpen className="size-10 opacity-40" />
              <p>
                {query
                  ? "검색 결과가 없어요"
                  : "교안이 없어요. PDF를 여기에 놓아주세요."}
              </p>
            </div>
          )}
        </div>
      </ScrollArea>
    </div>
  )
}
