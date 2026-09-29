import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type FormEvent,
  type CSSProperties,
  type DragEvent,
} from "react"
import {
  BookOpen,
  ChevronDown,
  Download,
  FileText,
  FolderOpen,
  FolderInput,
  FolderPlus,
  Library,
  Loader2,
  Moon,
  Pencil,
  Plus,
  RefreshCw,
  Search,
  Settings2,
  Sparkles,
  Sun,
  Trash2,
  Upload,
} from "lucide-react"
import { toast } from "sonner"
import { api } from "@/lib/api"
import {
  draggedDocumentIds,
  isDocumentDrag,
  type LibrarySelection,
} from "@/lib/library"
import {
  DEFAULT_IMPORT_EXTENSIONS,
  dropFolder,
  isDocumentFile,
  isFileDrag,
} from "@/lib/imports"
import {
  loadQuestionDrafts,
  mergeLookup,
  persistQuestionDrafts,
  readRoute,
  selectedEngine,
} from "@/lib/reader"
import type {
  Doc,
  Folder,
  Lookup,
  LookupInput,
  Question,
  SpeechContext,
  SpeechSettings,
  Vocab,
} from "@/lib/types"
import { useModels } from "@/hooks/useModels"
import { useTheme } from "@/components/theme-provider"
import { FitDot } from "@/components/FitDot"
import { ModelSettings } from "@/components/ModelSettings"
import { ModelDownloads } from "@/components/ModelDownloads"
import { Reader } from "@/components/Reader"
import { NotesPanel, type PendingQuestion } from "@/components/NotesPanel"
import { FolderSelect } from "@/components/FolderSelect"
import { FolderActions } from "@/components/FolderActions"
import { DocActions } from "@/components/DocActions"
import { DocumentLibrary } from "@/components/DocumentLibrary"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent } from "@/components/ui/card"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarSeparator,
  SidebarTrigger,
} from "@/components/ui/sidebar"
import { ScrollArea } from "@/components/ui/scroll-area"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { Toaster } from "@/components/ui/sonner"

const abortError = (error: unknown) =>
  error instanceof DOMException && error.name === "AbortError"
const errorText = (error: unknown) =>
  error instanceof Error ? error.message : String(error)
const providerNames = { codex: "Codex", local: "로컬", claude: "Claude" }

export function App() {
  const [route, setRoute] = useState(readRoute)
  const [docs, setDocs] = useState<Doc[]>([])
  const [folders, setFolders] = useState<Folder[]>([])
  const [vocab, setVocab] = useState<Vocab[]>([])
  const [loadingLibrary, setLoadingLibrary] = useState(true)
  const [session, setSession] = useState<{
    doc: Doc
    lookups: Lookup[]
    questions: Question[]
  } | null>(null)
  const [readerError, setReaderError] = useState("")
  const [reload, setReload] = useState(0)
  const [tab, setTab] = useState("words")
  const [query, setQuery] = useState("")
  const [uploadOpen, setUploadOpen] = useState(false)
  const [uploadFile, setUploadFile] = useState<File | null>(null)
  const [uploadFolder, setUploadFolder] = useState("")
  const [folderOpen, setFolderOpen] = useState(false)
  const [folderName, setFolderName] = useState("")
  const [renamingFolder, setRenamingFolder] = useState<Folder | null>(null)
  const [folderBusy, setFolderBusy] = useState(false)
  const [movingDocs, setMovingDocs] = useState<Doc[]>([])
  const [destinationFolder, setDestinationFolder] = useState("")
  const [moving, setMoving] = useState(false)
  const [docAction, setDocAction] = useState<{
    kind: "rename" | "delete"
    doc: Doc
  } | null>(null)
  const [docName, setDocName] = useState("")
  const [docBusy, setDocBusy] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [importProgress, setImportProgress] = useState<{
    name: string
    index: number
    total: number
  } | null>(null)
  const [importExtensions, setImportExtensions] = useState(
    DEFAULT_IMPORT_EXTENSIONS
  )
  const [dragTarget, setDragTarget] = useState<string | null>(null)
  const [draggedIds, setDraggedIds] = useState<string[]>([])
  const [deletingItems, setDeletingItems] = useState<LibrarySelection | null>(
    null
  )
  const [deletingFolder, setDeletingFolder] = useState<Folder | null>(null)
  const [removingFolder, setRemovingFolder] = useState(false)
  const [modelPopover, setModelPopover] = useState(false)
  const [downloadsOpen, setDownloadsOpen] = useState(false)
  const [downloadsTab, setDownloadsTab] = useState<"translation" | "speech">(
    "translation"
  )
  const [speechSettings, setSpeechSettings] = useState<SpeechSettings | null>(
    null
  )
  const [pendingQuestions, setPendingQuestions] =
    useState<PendingQuestion[]>(loadQuestionDrafts)
  const [exporting, setExporting] = useState(false)
  const [exportConfirm, setExportConfirm] = useState(false)
  const [ankiBusy, setAnkiBusy] = useState(false)
  const librarySeq = useRef({ revision: 0 })
  const lookupRevision = useRef(0)
  const deletedDocs = useRef(new Set<string>())
  const speechSettingsRevision = useRef({ revision: 0 })
  const uploadInput = useRef<HTMLInputElement>(null)
  const importing = useRef(false)
  const movingBatch = useRef(false)
  const modelState = useModels()
  const { theme, setTheme } = useTheme()
  const doc = session?.doc.id === route.docId ? session.doc : null
  const currentFolder = folders.find((folder) => folder.id === route.folderId)
  const page = doc ? Math.min(route.page, doc.pages - 1) : route.page
  const lookups = doc ? session!.lookups : []
  const questions = doc ? session!.questions : []
  const pendingCount = lookups.filter((row) => row.status === "pending").length
  const engine = selectedEngine(modelState.settings)
  const currentModel =
    engine &&
    modelState.models?.[engine.provider].find((m) => m.id === engine.model)

  const visiblePageChanged = useCallback(
    (next: number) => {
      const current = readRoute()
      if (
        !route.docId ||
        current.docId !== route.docId ||
        current.page === next
      )
        return
      history.replaceState(
        history.state,
        "",
        `#/doc/${route.docId}/${next + 1}`
      )
      setRoute(readRoute())
    },
    [route.docId]
  )

  useEffect(() => {
    const controller = new AbortController()
    api<{ extensions: string[] }>("/api/import/formats", {
      signal: controller.signal,
    })
      .then((value) => {
        if (!controller.signal.aborted) setImportExtensions(value.extensions)
      })
      .catch(() => {
        /* 기본 형식 목록을 유지하고 업로드 실패는 응답으로 안내한다. */
      })
    const preventFileNavigation = (event: globalThis.DragEvent) => {
      if (isFileDrag(event.dataTransfer) || isDocumentDrag(event.dataTransfer))
        event.preventDefault()
    }
    const clearDrag = () => {
      setDragTarget(null)
      setDraggedIds([])
    }
    window.addEventListener("dragover", preventFileNavigation)
    window.addEventListener("drop", preventFileNavigation)
    window.addEventListener("drop", clearDrag)
    window.addEventListener("dragend", clearDrag)
    window.addEventListener("blur", clearDrag)
    return () => {
      controller.abort()
      window.removeEventListener("dragover", preventFileNavigation)
      window.removeEventListener("drop", preventFileNavigation)
      window.removeEventListener("drop", clearDrag)
      window.removeEventListener("dragend", clearDrag)
      window.removeEventListener("blur", clearDrag)
    }
  }, [])

  const refreshSpeechSettings = useCallback(async () => {
    const guard = speechSettingsRevision.current
    const revision = ++guard.revision
    try {
      const value = await api<SpeechSettings>("/api/stt/settings")
      if (revision === guard.revision) setSpeechSettings(value)
    } catch (error) {
      if (revision === guard.revision)
        toast.error("음성 인식 설정을 불러오지 못했습니다", {
          description: errorText(error),
        })
    }
  }, [])
  useEffect(() => {
    const guard = speechSettingsRevision.current
    // The callback only updates state after the server responds.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void refreshSpeechSettings()
    return () => {
      guard.revision++
    }
  }, [refreshSpeechSettings])

  useEffect(() => {
    if (!persistQuestionDrafts(pendingQuestions))
      toast.error("임시 질문을 보관하지 못했습니다. 원문을 복사해 주세요.", {
        id: "draft-storage",
      })
  }, [pendingQuestions])

  useEffect(() => {
    const change = () => {
      setRoute(readRoute())
      setReaderError("")
      setQuery("")
    }
    window.addEventListener("hashchange", change)
    return () => window.removeEventListener("hashchange", change)
  }, [])
  const refreshLibrary = useCallback(async () => {
    const guard = librarySeq.current
    const request = ++guard.revision
    try {
      const [documents, words, courses] = await Promise.all([
        api<Doc[]>("/api/docs"),
        api<Vocab[]>("/api/vocab"),
        api<Folder[]>("/api/folders"),
      ])
      if (request === guard.revision) {
        setDocs(documents)
        setVocab(words)
        setFolders(courses)
      }
    } catch (error) {
      if (request === guard.revision)
        toast.error("목록을 불러오지 못했습니다", {
          description: errorText(error),
        })
    } finally {
      if (request === guard.revision) setLoadingLibrary(false)
    }
  }, [])
  // refreshLibrary updates React state only after its network requests settle.
  useEffect(() => {
    const guard = librarySeq.current
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void refreshLibrary()
    return () => {
      guard.revision++
    }
  }, [refreshLibrary])
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (route.view === "vocab" && !route.docId) void refreshLibrary()
  }, [route.docId, route.view, refreshLibrary])
  useEffect(() => {
    if (!route.docId) return
    const controller = new AbortController(),
      id = route.docId
    Promise.all([
      api<Doc>(`/api/docs/${id}`, { signal: controller.signal }),
      api<Lookup[]>(`/api/docs/${id}/lookups`, { signal: controller.signal }),
      api<Question[]>(`/api/docs/${id}/questions`, {
        signal: controller.signal,
      }),
    ])
      .then(([document, rows, qs]) => {
        if (!controller.signal.aborted && !deletedDocs.current.has(id)) {
          setSession({ doc: document, lookups: rows, questions: qs })
          setReaderError("")
        }
      })
      .catch((error) => {
        if (!controller.signal.aborted && !abortError(error))
          setReaderError(errorText(error))
      })
    return () => controller.abort()
  }, [route.docId, reload])
  useEffect(() => {
    if (!route.docId || !pendingCount) return
    const id = route.docId,
      controller = new AbortController()
    let timer: ReturnType<typeof setTimeout>
    const poll = async () => {
      const revision = lookupRevision.current
      try {
        const rows = await api<Lookup[]>(`/api/docs/${id}/lookups`, {
          signal: controller.signal,
        })
        if (revision === lookupRevision.current && !controller.signal.aborted) {
          setSession((current) =>
            current?.doc.id === id ? { ...current, lookups: rows } : current
          )
        }
      } catch (error) {
        if (!abortError(error)) console.error("번역 상태 확인 실패", error)
      }
      if (!controller.signal.aborted) timer = setTimeout(poll, 1500)
    }
    timer = setTimeout(poll, 1000)
    return () => {
      clearTimeout(timer)
      controller.abort()
    }
  }, [route.docId, pendingCount])

  const lookup = async (id: string, input: LookupInput) => {
    lookupRevision.current++
    try {
      const row = await api<Lookup>(`/api/docs/${id}/lookup`, {
        method: "POST",
        body: JSON.stringify(input),
      })
      setSession((current) =>
        current?.doc.id === id
          ? { ...current, lookups: mergeLookup(current.lookups, row) }
          : current
      )
      if (readRoute().docId === id) {
        setTab(input.kind === "word" ? "words" : "sentences")
      }
      return true
    } catch (error) {
      toast.error("조회하지 못했습니다", { description: errorText(error) })
      return false
    } finally {
      lookupRevision.current++
    }
  }
  const saveQuestion = async (
    id: string,
    raw: string,
    fix: boolean,
    capturedEngine = engine
  ) => {
    if (deletedDocs.current.has(id)) return false
    try {
      const q = await api<Question>(`/api/docs/${id}/questions`, {
        method: "POST",
        body: JSON.stringify({ raw, fix, engine: capturedEngine }),
      })
      if (deletedDocs.current.has(id)) return false
      setSession((current) =>
        current?.doc.id === id
          ? { ...current, questions: [...current.questions, q] }
          : current
      )
      if (q.error)
        toast.error("원문은 저장했지만 교정하지 못했습니다", {
          description: q.error,
        })
      return true
    } catch (error) {
      if (deletedDocs.current.has(id)) return false
      toast.error("질문을 저장하지 못했습니다", {
        description: errorText(error),
      })
      return false
    }
  }
  const receiveAudio = async (blob: Blob, context: SpeechContext) => {
    const id = crypto.randomUUID()
    setPendingQuestions((current) => [
      ...current,
      { id, docId: context.docId, raw: "", stage: "받아쓰는 중…" },
    ])
    setTab("questions")
    try {
      const data = new FormData()
      data.append("file", blob, "question.webm")
      data.append("selection", JSON.stringify(context.stt))
      const value = await api<{ raw: string }>(
        `/api/docs/${context.docId}/questions/audio`,
        { method: "POST", body: data }
      )
      if (deletedDocs.current.has(context.docId)) return
      setPendingQuestions((current) =>
        current.map((item) =>
          item.id === id
            ? { ...item, raw: value.raw, stage: "용어를 정리하는 중…" }
            : item
        )
      )
      if (
        !(await saveQuestion(context.docId, value.raw, true, context.engine))
      ) {
        setPendingQuestions((current) =>
          current.map((q) =>
            q.id === id
              ? { ...q, failed: true, stage: "저장하지 못한 질문" }
              : q
          )
        )
      }
    } catch (error) {
      if (!deletedDocs.current.has(context.docId))
        toast.error("받아쓰기를 완료하지 못했습니다", {
          description: errorText(error),
        })
    } finally {
      setPendingQuestions((current) =>
        current.filter((item) => item.id !== id || item.failed)
      )
    }
  }
  const copyPrompt = async (kind: "summary" | "questions") => {
    try {
      const result = await api<{ prompt: string }>(
        kind === "summary"
          ? "/api/prompts/summary"
          : `/api/docs/${doc!.id}/questions/prompt`
      )
      await navigator.clipboard.writeText(result.prompt)
      toast.success("프롬프트를 복사했어요")
    } catch (error) {
      toast.error("복사하지 못했습니다", { description: errorText(error) })
    }
  }
  const exportPdf = async () => {
    if (!doc) return
    const id = doc.id
    setExporting(true)
    setExportConfirm(false)
    try {
      await api(`/api/docs/${id}/export`, { method: "POST" })
      const link = document.createElement("a")
      link.href = `/api/docs/${id}/export/download`
      link.download = ""
      link.click()
      toast.success("번역 PDF를 만들었어요")
    } catch (error) {
      toast.error("PDF를 만들지 못했습니다", { description: errorText(error) })
    } finally {
      setExporting(false)
    }
  }
  const exportAnki = async () => {
    setAnkiBusy(true)
    try {
      const result = await api<{ files: string[]; count: number }>(
        "/api/anki",
        { method: "POST" }
      )
      toast.success(`${result.count}개 단어로 Anki 덱을 만들었어요`, {
        duration: 12000,
        action: {
          label: "저장 위치 복사",
          onClick: () =>
            void navigator.clipboard.writeText(result.files.join("\n")),
        },
      })
    } catch (error) {
      toast.error("덱을 만들지 못했습니다", { description: errorText(error) })
    } finally {
      setAnkiBusy(false)
    }
  }
  const openUpload = () => {
    if (importing.current) return
    setUploadFile(null)
    setUploadFolder(route.folderId ?? doc?.folder_id ?? "")
    setUploadOpen(true)
  }
  const removeFolder = async () => {
    if (!deletingFolder || removingFolder) return
    const target = deletingFolder
    setRemovingFolder(true)
    librarySeq.current.revision++
    lookupRevision.current++
    try {
      const result = await api<{
        ok: boolean
        deleted_doc_ids: string[]
        warning?: string
      }>(`/api/folders/${target.id}`, { method: "DELETE" })
      const ids = new Set(result.deleted_doc_ids)
      ids.forEach((id) => deletedDocs.current.add(id))
      setDocs((current) => current.filter((item) => !ids.has(item.id)))
      setFolders((current) =>
        current.filter((folder) => folder.id !== target.id)
      )
      setSession((current) =>
        current && ids.has(current.doc.id) ? null : current
      )
      setPendingQuestions((current) =>
        current.filter((item) => !ids.has(item.docId))
      )
      const active = readRoute()
      if (
        active.folderId === target.id ||
        (active.docId && ids.has(active.docId))
      ) {
        setExportConfirm(false)
        location.hash = "#/"
      }
      setDeletingFolder(null)
      if (result.warning) toast.warning(result.warning, { duration: 12000 })
      else toast.success("폴더와 안의 교안을 삭제했어요")
    } catch (error) {
      toast.error("폴더를 삭제하지 못했습니다", {
        description: errorText(error),
      })
    } finally {
      lookupRevision.current++
      setRemovingFolder(false)
      await refreshLibrary()
    }
  }
  const openCreateFolder = () => {
    setRenamingFolder(null)
    setFolderName("")
    setFolderOpen(true)
  }
  const openRenameFolder = (folder: Folder) => {
    setRenamingFolder(folder)
    setFolderName(folder.name)
    setFolderOpen(true)
  }
  const createFolder = async (event: FormEvent) => {
    event.preventDefault()
    if (!folderName.trim() || folderBusy) return
    setFolderBusy(true)
    librarySeq.current.revision++
    try {
      const folder = await api<Folder>(
        renamingFolder ? `/api/folders/${renamingFolder.id}` : "/api/folders",
        {
          method: renamingFolder ? "PATCH" : "POST",
          body: JSON.stringify({ name: folderName.trim() }),
        }
      )
      setFolders((current) =>
        [...current.filter((item) => item.id !== folder.id), folder].sort(
          (a, b) => a.name.localeCompare(b.name, "ko")
        )
      )
      if (renamingFolder) {
        setDocs((current) =>
          current.map((item) =>
            item.folder_id === folder.id
              ? { ...item, subject: folder.name }
              : item
          )
        )
        setSession((current) =>
          current?.doc.folder_id === folder.id
            ? { ...current, doc: { ...current.doc, subject: folder.name } }
            : current
        )
      }
      setFolderOpen(false)
      setFolderName("")
      toast.success(
        renamingFolder
          ? "폴더 이름을 변경했어요"
          : `‘${folder.name}’ 폴더를 만들었어요`
      )
    } catch (error) {
      toast.error("폴더를 저장하지 못했습니다", {
        description: errorText(error),
      })
    } finally {
      librarySeq.current.revision++
      setFolderBusy(false)
      await refreshLibrary()
    }
  }
  const openRename = (document: Doc) => {
    setDocName(document.name)
    setDocAction({ kind: "rename", doc: document })
  }
  const openMove = (document: Doc) => {
    setMovingDocs([document])
    setDestinationFolder(document.folder_id ?? "")
  }
  const openMoveDocuments = (ids: string[]) => {
    const selected = docs.filter((item) => ids.includes(item.id))
    if (!selected.length) return
    setMovingDocs(selected)
    setDestinationFolder(selected[0].folder_id ?? "")
  }
  const openDelete = (document: Doc) =>
    setDocAction({ kind: "delete", doc: document })
  const updateDocument = (updated: Doc) => {
    setDocs((current) =>
      current.map((item) => (item.id === updated.id ? updated : item))
    )
    setSession((current) =>
      current?.doc.id === updated.id ? { ...current, doc: updated } : current
    )
  }
  const submitDocAction = async (event: FormEvent) => {
    event.preventDefault()
    if (!docAction || docBusy) return
    const { kind, doc: target } = docAction
    if (kind === "rename" && !docName.trim()) return
    setDocBusy(true)
    librarySeq.current.revision++
    lookupRevision.current++
    try {
      if (kind === "rename") {
        const updated = await api<Doc>(`/api/docs/${target.id}`, {
          method: "PATCH",
          body: JSON.stringify({ name: docName.trim() }),
        })
        updateDocument(updated)
        toast.success("교안 이름을 변경했어요")
      } else {
        const result = await api<{ ok: boolean; warning?: string }>(
          `/api/docs/${target.id}`,
          { method: "DELETE" }
        )
        deletedDocs.current.add(target.id)
        setDocs((current) => current.filter((item) => item.id !== target.id))
        setSession((current) =>
          current?.doc.id === target.id ? null : current
        )
        setPendingQuestions((current) =>
          current.filter((item) => item.docId !== target.id)
        )
        if (readRoute().docId === target.id) {
          setExportConfirm(false)
          location.hash = target.folder_id
            ? `#/folder/${target.folder_id}`
            : "#/"
        }
        if (result.warning) toast.warning(result.warning, { duration: 12000 })
        else toast.success("교안을 삭제했어요")
      }
      setDocAction(null)
    } catch (error) {
      toast.error(
        kind === "rename"
          ? "이름을 변경하지 못했습니다"
          : "교안을 삭제하지 못했습니다",
        { description: errorText(error) }
      )
    } finally {
      lookupRevision.current++
      setDocBusy(false)
      await refreshLibrary()
    }
  }
  const moveDocuments = async (ids: string[], folderId: string | null) => {
    if (
      !ids.length ||
      movingBatch.current ||
      uploading ||
      docBusy ||
      removingFolder
    )
      return false
    if (ids.length > 500) {
      toast.error("한 번에 500개까지 옮길 수 있습니다.")
      return false
    }
    if (
      ids.every((id) =>
        docs.some(
          (item) => item.id === id && (item.folder_id ?? null) === folderId
        )
      )
    )
      return true
    movingBatch.current = true
    setMoving(true)
    librarySeq.current.revision++
    try {
      const result = await api<{ docs: Doc[] }>("/api/docs/move", {
        method: "POST",
        body: JSON.stringify({ doc_ids: ids, folder_id: folderId }),
      })
      const updated = new Map(result.docs.map((item) => [item.id, item]))
      setDocs((current) => current.map((item) => updated.get(item.id) ?? item))
      setSession((current) =>
        current && updated.has(current.doc.id)
          ? { ...current, doc: updated.get(current.doc.id)! }
          : current
      )
      toast.success(`${result.docs.length}개의 교안을 옮겼어요`)
      return true
    } catch (error) {
      toast.error("교안을 옮기지 못했습니다", { description: errorText(error) })
      return false
    } finally {
      setMoving(false)
      movingBatch.current = false
      await refreshLibrary()
    }
  }
  const moveDoc = async (event: FormEvent) => {
    event.preventDefault()
    if (
      await moveDocuments(
        movingDocs.map((item) => item.id),
        destinationFolder || null
      )
    )
      setMovingDocs([])
  }
  const removeLibraryItems = async () => {
    if (!deletingItems || docBusy) return
    setDocBusy(true)
    librarySeq.current.revision++
    lookupRevision.current++
    const removedDocs = new Set<string>(),
      removedFolders = new Set<string>()
    const failed: LibrarySelection = { docIds: [], folderIds: [] }
    const errors: string[] = [],
      warnings: string[] = []
    try {
      for (const id of deletingItems.folderIds) {
        try {
          const result = await api<{
            deleted_doc_ids: string[]
            warning?: string
          }>(`/api/folders/${id}`, { method: "DELETE" })
          removedFolders.add(id)
          result.deleted_doc_ids.forEach((docId) => {
            removedDocs.add(docId)
            deletedDocs.current.add(docId)
          })
          if (result.warning) warnings.push(result.warning)
        } catch (error) {
          failed.folderIds.push(id)
          errors.push(errorText(error))
        }
      }
      for (const id of deletingItems.docIds) {
        if (removedDocs.has(id)) continue
        try {
          const result = await api<{ warning?: string }>(`/api/docs/${id}`, {
            method: "DELETE",
          })
          removedDocs.add(id)
          deletedDocs.current.add(id)
          if (result.warning) warnings.push(result.warning)
        } catch (error) {
          failed.docIds.push(id)
          errors.push(errorText(error))
        }
      }
      setDocs((current) => current.filter((item) => !removedDocs.has(item.id)))
      setFolders((current) =>
        current.filter((item) => !removedFolders.has(item.id))
      )
      setSession((current) =>
        current && removedDocs.has(current.doc.id) ? null : current
      )
      setPendingQuestions((current) =>
        current.filter((item) => !removedDocs.has(item.docId))
      )
      const active = readRoute()
      if (
        (active.docId && removedDocs.has(active.docId)) ||
        (active.folderId && removedFolders.has(active.folderId))
      )
        location.hash = "#/"
      setDeletingItems(errors.length ? failed : null)
      if (errors.length)
        toast.error("일부 항목을 삭제하지 못했습니다", {
          description: errors[0],
        })
      if (warnings.length) toast.warning(warnings[0], { duration: 12000 })
      if (!errors.length && !warnings.length)
        toast.success("선택한 항목을 삭제했어요")
    } finally {
      lookupRevision.current++
      setDocBusy(false)
      await refreshLibrary()
    }
  }
  const importDocuments = async (
    files: File[],
    folderId: string | null,
    openReader = false
  ) => {
    if (importing.current || removingFolder) {
      toast("진행 중인 작업이 끝난 뒤 파일을 추가해 주세요.")
      return
    }
    const accepted = files.filter((file) =>
      isDocumentFile(file, importExtensions)
    )
    if (accepted.length !== files.length)
      toast.error("지원하지 않는 파일 형식이 포함되어 있습니다", {
        description: importExtensions.join(", "),
      })
    if (!accepted.length) return
    importing.current = true
    setUploading(true)
    librarySeq.current.revision++
    let completed = 0
    try {
      for (const [index, file] of accepted.entries()) {
        setImportProgress({
          name: file.name,
          index: index + 1,
          total: accepted.length,
        })
        const data = new FormData()
        data.append("file", file)
        data.append("folder_id", folderId ?? "")
        try {
          const document = await api<Doc>("/api/docs", {
            method: "POST",
            body: data,
          })
          completed++
          setDocs((current) => [
            document,
            ...current.filter((item) => item.id !== document.id),
          ])
          if (openReader) {
            setUploadOpen(false)
            setUploadFile(null)
            setUploadFolder("")
            location.hash = `#/doc/${document.id}/1`
          }
        } catch (error) {
          toast.error(`${file.name} 파일을 추가하지 못했습니다`, {
            description: errorText(error),
            duration: 10000,
          })
        }
      }
      if (completed && !openReader)
        toast.success(`${completed}개의 교안을 추가했어요`)
    } finally {
      importing.current = false
      setUploading(false)
      setImportProgress(null)
      await refreshLibrary()
    }
  }
  const upload = async (event: FormEvent) => {
    event.preventDefault()
    if (uploadFile)
      await importDocuments([uploadFile], uploadFolder || null, true)
  }
  const selectUploadFiles = (files: File[]) => {
    if (importing.current) return
    if (files.length !== 1) {
      setUploadFile(null)
      if (uploadInput.current) uploadInput.current.value = ""
      toast.error("추가 창에서는 파일을 하나씩 선택해 주세요.")
      return
    }
    if (!isDocumentFile(files[0], importExtensions)) {
      setUploadFile(null)
      if (uploadInput.current) uploadInput.current.value = ""
      toast.error("지원하지 않는 파일 형식입니다", {
        description: importExtensions.join(", "),
      })
      return
    }
    setUploadFile(files[0])
    if (uploadInput.current) {
      const transfer = new DataTransfer()
      transfer.items.add(files[0])
      uploadInput.current.files = transfer.files
    }
  }
  const dragOver = (event: DragEvent<HTMLDivElement>) => {
    const internal = isDocumentDrag(event.dataTransfer)
    if (!internal && !isFileDrag(event.dataTransfer)) return
    event.preventDefault()
    const target = event.target instanceof Element ? event.target : null
    if (
      target?.closest('[role="dialog"],[role="menu"]') ||
      uploading ||
      removingFolder ||
      moving ||
      docBusy
    )
      return
    if (
      (route.docId || route.view !== "library") &&
      !target?.closest("[data-folder-drop]")
    )
      return
    event.dataTransfer.dropEffect = internal ? "move" : "copy"
    setDragTarget(dropFolder(target, route.folderId) ?? "root")
  }
  const dropDocuments = (event: DragEvent<HTMLDivElement>) => {
    const internal = isDocumentDrag(event.dataTransfer)
    if (!internal && !isFileDrag(event.dataTransfer)) return
    event.preventDefault()
    event.stopPropagation()
    setDragTarget(null)
    setDraggedIds([])
    const target = event.target instanceof Element ? event.target : null
    if (target?.closest('[role="dialog"],[role="menu"]')) return
    if (
      (route.docId || route.view !== "library") &&
      !target?.closest("[data-folder-drop]")
    )
      return
    if (internal) {
      const ids = draggedDocumentIds(event.dataTransfer)
      if (!ids.length) {
        toast.error("이동할 교안을 다시 선택해 주세요.")
        return
      }
      void moveDocuments(ids, dropFolder(target, route.folderId))
      return
    }
    void importDocuments(
      Array.from(event.dataTransfer.files),
      dropFolder(target, route.folderId)
    )
  }
  const mutateLookup = async (id: number, retry = false) => {
    const docId = doc?.id
    lookupRevision.current++
    try {
      await api(`/api/lookups/${id}${retry ? "/retry" : ""}`, {
        method: retry ? "POST" : "DELETE",
      })
      setSession((current) =>
        current && current.doc.id === docId
          ? {
              ...current,
              lookups: retry
                ? current.lookups.map((row) =>
                    row.id === id ? { ...row, status: "pending" } : row
                  )
                : current.lookups.filter((row) => row.id !== id),
            }
          : current
      )
    } catch (error) {
      toast.error("변경하지 못했습니다", { description: errorText(error) })
    } finally {
      lookupRevision.current++
    }
  }
  const editQuestion = async (id: number, text: string) => {
    const docId = doc?.id
    await api(`/api/questions/${id}`, {
      method: "PUT",
      body: JSON.stringify({ text }),
    })
    setSession((current) =>
      current && current.doc.id === docId
        ? {
            ...current,
            questions: current.questions.map((q) =>
              q.id === id ? { ...q, text } : q
            ),
          }
        : current
    )
  }
  const deleteQuestion = async (id: number) => {
    const docId = doc?.id
    try {
      await api(`/api/questions/${id}`, { method: "DELETE" })
      setSession((current) =>
        current && current.doc.id === docId
          ? {
              ...current,
              questions: current.questions.filter((q) => q.id !== id),
            }
          : current
      )
    } catch (error) {
      toast.error("삭제하지 못했습니다", { description: errorText(error) })
    }
  }
  const notes = doc && (
    <NotesPanel
      key={doc.id}
      lookups={lookups.filter((row) => row.page === page)}
      questions={questions}
      pendingQuestions={pendingQuestions.filter((q) => q.docId === doc.id)}
      onSaveDraft={async (q) => {
        if (await saveQuestion(q.docId, q.raw, false))
          setPendingQuestions((current) =>
            current.filter((item) => item.id !== q.id)
          )
      }}
      onDeleteDraft={(id) =>
        setPendingQuestions((current) => current.filter((q) => q.id !== id))
      }
      tab={tab}
      onTabChange={setTab}
      onDeleteLookup={(id) => void mutateLookup(id)}
      onRetry={(id) => void mutateLookup(id, true)}
      onAdd={(text) => saveQuestion(doc.id, text, false)}
      onCopy={() => void copyPrompt("questions")}
      onEdit={editQuestion}
      onDeleteQuestion={(id) => void deleteQuestion(id)}
    />
  )
  const filteredDocs = docs.filter(
    (d) =>
      (d.folder_id ?? null) === route.folderId &&
      `${d.name} ${d.subject}`.toLowerCase().includes(query.toLowerCase())
  )
  const filteredFolders = folders.filter((folder) =>
    folder.name.toLowerCase().includes(query.toLowerCase())
  )
  const filteredVocab = vocab.filter((word) =>
    `${word.word} ${word.meaning} ${word.subject}`
      .toLowerCase()
      .includes(query.toLowerCase())
  )
  const openDownloads = (tab: "translation" | "speech" = "translation") => {
    setModelPopover(false)
    setDownloadsTab(tab)
    setDownloadsOpen(true)
  }

  return (
    <SidebarProvider
      className="h-svh min-h-0 overflow-hidden"
      style={{ "--sidebar-width": "15rem" } as CSSProperties}
      onDragOver={dragOver}
      onDrop={dropDocuments}
      onDragLeave={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null))
          setDragTarget(null)
      }}
    >
      <Sidebar collapsible="icon" className="border-r">
        <SidebarHeader className="p-4 group-data-[collapsible=icon]:px-1.5">
          <a
            href="#/"
            aria-label="영한번역 홈"
            className="flex items-center gap-2.5 group-data-[collapsible=icon]:justify-center"
          >
            <div className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-primary text-primary-foreground">
              <BookOpen className="size-5" />
            </div>
            <div className="group-data-[collapsible=icon]:hidden">
              <span className="text-sm font-bold tracking-tight">영한번역</span>
              <p className="text-[10px] tracking-[.12em] text-muted-foreground">
                나의 교안 읽기 공간
              </p>
            </div>
          </a>
        </SidebarHeader>
        <SidebarContent>
          <SidebarGroup>
            <SidebarGroupContent>
              <SidebarMenu>
                <SidebarMenuItem>
                  <SidebarMenuButton
                    isActive={
                      !route.docId &&
                      !route.folderId &&
                      route.view === "library"
                    }
                    render={<a href="#/" data-folder-drop="" />}
                    tooltip="내 교안"
                  >
                    <Library />
                    <span>내 교안</span>
                  </SidebarMenuButton>
                </SidebarMenuItem>
                <SidebarMenuItem>
                  <SidebarMenuButton
                    isActive={!route.docId && route.view === "vocab"}
                    render={<a href="#/vocab" />}
                    tooltip="단어장"
                  >
                    <BookOpen />
                    <span>단어장</span>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
          <SidebarSeparator />
          {folders.length > 0 && (
            <SidebarGroup>
              <SidebarGroupLabel>과목 폴더</SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  {folders.map((folder) => (
                    <SidebarMenuItem
                      key={folder.id}
                      data-folder-drop={folder.id}
                      className={
                        dragTarget === folder.id
                          ? "rounded-md bg-primary/10 ring-2 ring-primary"
                          : ""
                      }
                    >
                      <SidebarMenuButton
                        isActive={route.folderId === folder.id}
                        render={<a href={`#/folder/${folder.id}`} />}
                        tooltip={folder.name}
                        className="pr-9 group-data-[collapsible=icon]:pr-2"
                      >
                        <FolderOpen />
                        <span>{folder.name}</span>
                      </SidebarMenuButton>
                      <FolderActions
                        folder={folder}
                        onDelete={setDeletingFolder}
                        onRename={openRenameFolder}
                        disabled={removingFolder || uploading || docBusy}
                        className="absolute top-0.5 right-0.5 group-data-[collapsible=icon]:hidden"
                      />
                    </SidebarMenuItem>
                  ))}
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          )}
          <SidebarGroup>
            <SidebarGroupLabel>최근 교안</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {docs.map((d) => (
                  <SidebarMenuItem key={d.id}>
                    <SidebarMenuButton
                      isActive={route.docId === d.id}
                      render={<a href={`#/doc/${d.id}/1`} />}
                      tooltip={d.name}
                    >
                      <FileText />
                      <span>{d.name}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
                {!docs.length && (
                  <p className="px-2 py-3 text-xs text-muted-foreground group-data-[collapsible=icon]:hidden">
                    아직 등록한 교안이 없어요.
                  </p>
                )}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        </SidebarContent>
        <SidebarFooter className="gap-2 p-3 group-data-[collapsible=icon]:px-2">
          <SidebarMenu>
            <SidebarMenuItem>
              <SidebarMenuButton
                onClick={() => openDownloads()}
                tooltip="모델 관리"
              >
                <Settings2 />
                <span>모델 관리</span>
              </SidebarMenuButton>
            </SidebarMenuItem>
            <SidebarMenuItem>
              <SidebarMenuButton
                onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
                tooltip="테마 변경"
              >
                {theme === "dark" ? <Sun /> : <Moon />}
                <span>{theme === "dark" ? "밝은 화면" : "어두운 화면"}</span>
              </SidebarMenuButton>
            </SidebarMenuItem>
          </SidebarMenu>
          <Button
            aria-label="교안 추가"
            onClick={openUpload}
            disabled={uploading || removingFolder}
            className="group-data-[collapsible=icon]:size-8 group-data-[collapsible=icon]:p-0"
          >
            <Plus />
            <span className="group-data-[collapsible=icon]:hidden">
              교안 추가
            </span>
          </Button>
        </SidebarFooter>
      </Sidebar>
      <SidebarInset
        className={`h-svh min-w-0 overflow-hidden ${dragTarget === (route.folderId ?? "root") && !route.docId ? "ring-2 ring-primary ring-inset" : ""}`}
      >
        <header className="flex min-h-16 shrink-0 items-center justify-between gap-3 border-b bg-background px-4 md:px-6">
          <div className="flex min-w-0 items-center gap-3">
            <SidebarTrigger aria-label="사이드바 열기·닫기" />
            <span className="h-5 w-px bg-border" />
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold">
                {doc?.name ||
                  (route.docId
                    ? "교안 불러오는 중…"
                    : route.view === "vocab"
                      ? "단어장"
                      : currentFolder?.name || "내 교안")}
              </p>
              {doc?.subject && (
                <p className="truncate text-[11px] text-muted-foreground">
                  {doc.subject}
                </p>
              )}
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {doc && (
              <DocActions
                doc={doc}
                onRename={openRename}
                onMove={openMove}
                onDelete={openDelete}
                disabled={docBusy || moving || exporting}
              />
            )}
            {pendingCount > 0 && (
              <span className="hidden items-center gap-1.5 text-xs text-muted-foreground sm:flex">
                <Loader2 className="size-3 animate-spin" />
                {pendingCount}건 처리 중
              </span>
            )}
            <Popover open={modelPopover} onOpenChange={setModelPopover}>
              <PopoverTrigger
                render={
                  <Button
                    variant="outline"
                    className="max-w-64 rounded-full px-3"
                  />
                }
              >
                {engine?.provider === "local" ? (
                  <FitDot fit={currentModel?.fit} />
                ) : (
                  <Sparkles className="size-3.5 text-primary" />
                )}
                <span className="max-w-40 truncate text-xs">
                  {engine
                    ? `${providerNames[engine.provider]} · ${engine.model}`
                    : "AI 설정"}
                </span>
                <ChevronDown className="size-3 opacity-50" />
              </PopoverTrigger>
              <PopoverContent
                align="end"
                className="w-[min(380px,calc(100vw-2rem))] p-5"
              >
                <ModelSettings
                  settings={modelState.settings}
                  models={modelState.models}
                  busy={modelState.busy}
                  onChange={modelState.change}
                  onRefresh={modelState.refresh}
                  onOpenDownloads={() => openDownloads()}
                />
              </PopoverContent>
            </Popover>
          </div>
        </header>
        {route.docId ? (
          <Reader
            key={route.docId}
            doc={doc}
            page={page}
            reload={reload}
            readerError={readerError}
            lookups={lookups}
            engine={engine}
            speechSettings={speechSettings}
            exporting={exporting}
            notes={notes}
            onReload={() => setReload((value) => value + 1)}
            onExport={() =>
              pendingCount ? setExportConfirm(true) : void exportPdf()
            }
            onTabChange={setTab}
            onVisiblePageChange={visiblePageChanged}
            onOpenSpeechSettings={() => openDownloads("speech")}
            onLookup={lookup}
            onAudio={receiveAudio}
          />
        ) : route.view === "library" ? (
          <DocumentLibrary
            docs={filteredDocs}
            folders={route.folderId ? [] : filteredFolders}
            currentFolder={currentFolder ?? null}
            query={query}
            onQueryChange={setQuery}
            loading={loadingLibrary}
            busy={moving || docBusy || uploading || removingFolder}
            dropTarget={dragTarget}
            onUpload={openUpload}
            onCreateFolder={openCreateFolder}
            onRefresh={() => {
              setLoadingLibrary(true)
              void refreshLibrary()
            }}
            onCopySummary={() => void copyPrompt("summary")}
            onRenameDoc={openRename}
            onRenameFolder={openRenameFolder}
            onMove={openMoveDocuments}
            onDelete={setDeletingItems}
            onDragDocuments={setDraggedIds}
            onDragEnd={() => {
              setDraggedIds([])
              setDragTarget(null)
            }}
          />
        ) : (
          <ScrollArea className="min-h-0 flex-1">
            <div className="mx-auto max-w-6xl space-y-6 p-6 lg:p-10">
              <div className="flex flex-wrap items-center justify-between gap-4">
                <div>
                  <h1 className="text-2xl font-semibold">단어장</h1>
                  <p className="mt-2 text-sm text-muted-foreground">
                    {vocab.length}개의 단어
                  </p>
                </div>
                <Button disabled={ankiBusy} onClick={() => void exportAnki()}>
                  {ankiBusy ? (
                    <Loader2 className="animate-spin" />
                  ) : (
                    <Download />
                  )}
                  Anki 덱 내보내기
                </Button>
              </div>
              <div className="flex items-center gap-2">
                <div className="relative max-w-xs flex-1">
                  <Search className="absolute top-2.5 left-3 size-4 text-muted-foreground" />
                  <Input
                    aria-label="단어 검색"
                    placeholder="단어나 뜻 검색"
                    value={query}
                    onChange={(event) => setQuery(event.target.value)}
                    className="pl-9"
                  />
                </div>
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label="목록 새로고침"
                  onClick={() => void refreshLibrary()}
                >
                  <RefreshCw />
                </Button>
              </div>
              <Card>
                <CardContent className="p-0">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="pl-5">단어</TableHead>
                        <TableHead>뜻</TableHead>
                        <TableHead>과목 · 교안</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {filteredVocab.map((word) => (
                        <TableRow key={word.id}>
                          <TableCell className="pl-5 font-medium">
                            {word.word}
                          </TableCell>
                          <TableCell className="text-primary">
                            {word.meaning}
                          </TableCell>
                          <TableCell className="text-xs text-muted-foreground">
                            {word.subject}
                            <span className="mt-1 block">
                              {word.doc} · {word.page}쪽
                            </span>
                          </TableCell>
                        </TableRow>
                      ))}
                      {!filteredVocab.length && (
                        <TableRow>
                          <TableCell
                            colSpan={3}
                            className="h-40 text-center text-muted-foreground"
                          >
                            교안에서 조회한 단어가 여기에 모여요.
                          </TableCell>
                        </TableRow>
                      )}
                    </TableBody>
                  </Table>
                </CardContent>
              </Card>
            </div>
          </ScrollArea>
        )}
      </SidebarInset>
      {dragTarget && dragTarget !== "dialog" && (
        <div
          className="pointer-events-none fixed bottom-8 left-1/2 z-50 flex max-w-[calc(100vw-2rem)] -translate-x-1/2 items-center gap-3 rounded-xl border border-primary/30 bg-background px-5 py-4 text-sm shadow-lg"
          role="status"
        >
          <Upload className="size-5 shrink-0 text-primary" />
          <span>
            <strong>
              {folders.find((folder) => folder.id === dragTarget)?.name ||
                "메인"}
            </strong>
            에{" "}
            {draggedIds.length
              ? `${draggedIds.length}개 교안 이동`
              : "교안 추가"}
          </span>
        </div>
      )}
      {importProgress && !uploadOpen && (
        <div
          className="fixed bottom-6 left-1/2 z-40 flex max-w-[calc(100vw-2rem)] -translate-x-1/2 items-center gap-3 rounded-xl border bg-background px-5 py-3 text-sm shadow-lg"
          role="status"
        >
          <Loader2 className="size-4 shrink-0 animate-spin text-primary" />
          <div className="min-w-0">
            <p>
              교안 추가 중 · {importProgress.index}/{importProgress.total}
            </p>
            <p className="truncate text-xs text-muted-foreground">
              {importProgress.name}
            </p>
          </div>
        </div>
      )}
      <ModelDownloads
        open={downloadsOpen}
        onOpenChange={setDownloadsOpen}
        onComplete={modelState.refresh}
        initialTab={downloadsTab}
        onSpeechSettingsChange={refreshSpeechSettings}
      />
      <Dialog
        open={uploadOpen}
        onOpenChange={(open) => {
          if (!uploading) setUploadOpen(open)
        }}
      >
        <DialogContent
          className={`sm:max-w-md ${dragTarget === "dialog" ? "ring-2 ring-primary" : ""}`}
          onDragOver={(event) => {
            if (!isFileDrag(event.dataTransfer)) return
            event.preventDefault()
            event.stopPropagation()
            if (!uploading) {
              event.dataTransfer.dropEffect = "copy"
              setDragTarget("dialog")
            }
          }}
          onDragLeave={(event) => {
            event.stopPropagation()
            if (
              !event.currentTarget.contains(event.relatedTarget as Node | null)
            )
              setDragTarget(null)
          }}
          onDrop={(event) => {
            if (!isFileDrag(event.dataTransfer)) return
            event.preventDefault()
            event.stopPropagation()
            setDragTarget(null)
            selectUploadFiles(Array.from(event.dataTransfer.files))
          }}
        >
          <form onSubmit={(event) => void upload(event)} className="space-y-5">
            <DialogHeader>
              <DialogTitle>새 교안 추가</DialogTitle>
              <DialogDescription>
                PDF 파일을 선택하거나 이 창에 놓아주세요.
              </DialogDescription>
            </DialogHeader>
            <div className="space-y-2">
              <Label htmlFor="pdf-upload">교안 파일</Label>
              <Input
                id="pdf-upload"
                ref={uploadInput}
                type="file"
                accept={importExtensions.join(",")}
                required
                disabled={uploading}
                onChange={(e) => {
                  const files = Array.from(e.target.files ?? [])
                  if (files.length) selectUploadFiles(files)
                  else setUploadFile(null)
                }}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="upload-folder">과목 폴더</Label>
              <FolderSelect
                id="upload-folder"
                folders={folders}
                value={uploadFolder}
                onChange={setUploadFolder}
                disabled={uploading}
              />
            </div>
            <DialogFooter>
              <Button
                variant="outline"
                type="button"
                disabled={uploading}
                onClick={() => setUploadOpen(false)}
              >
                취소
              </Button>
              <Button type="submit" disabled={uploading || !uploadFile}>
                {uploading ? <Loader2 className="animate-spin" /> : <Plus />}
                {uploading ? "교안 추가 중" : "교안 열기"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
      <Dialog
        open={!!deletingFolder}
        onOpenChange={(open) => {
          if (!open && !removingFolder) setDeletingFolder(null)
        }}
      >
        <DialogContent
          className="sm:max-w-md"
          showCloseButton={!removingFolder}
        >
          <DialogHeader>
            <DialogTitle>폴더를 삭제할까요?</DialogTitle>
            <DialogDescription className="break-words">
              ‘{deletingFolder?.name}’ 폴더와 안의 모든 교안, 저장된 번역·질문이
              함께 삭제됩니다. 이 작업은 되돌릴 수 없습니다.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              disabled={removingFolder}
              onClick={() => setDeletingFolder(null)}
            >
              취소
            </Button>
            <Button
              variant="destructive"
              disabled={removingFolder}
              onClick={() => void removeFolder()}
            >
              {removingFolder ? (
                <Loader2 className="animate-spin" />
              ) : (
                <Trash2 />
              )}
              폴더 삭제
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog
        open={folderOpen}
        onOpenChange={(open) => {
          if (!folderBusy) setFolderOpen(open)
        }}
      >
        <DialogContent className="sm:max-w-md">
          <form
            onSubmit={(event) => void createFolder(event)}
            className="space-y-5"
          >
            <DialogHeader>
              <DialogTitle>
                {renamingFolder ? "폴더 이름 변경" : "새 폴더"}
              </DialogTitle>
              <DialogDescription>
                {renamingFolder
                  ? "폴더에 사용할 이름을 입력하세요."
                  : "같은 과목의 교안을 한곳에 모아 보세요."}
              </DialogDescription>
            </DialogHeader>
            <div className="space-y-2">
              <Label htmlFor="folder-name">폴더 이름</Label>
              <Input
                id="folder-name"
                value={folderName}
                onChange={(event) => setFolderName(event.target.value)}
                placeholder="예: 프로그래밍 언어론"
                maxLength={200}
                required
                disabled={folderBusy}
              />
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={folderBusy}
                onClick={() => setFolderOpen(false)}
              >
                취소
              </Button>
              <Button
                type="submit"
                disabled={
                  folderBusy ||
                  !folderName.trim() ||
                  folderName.trim() === renamingFolder?.name
                }
              >
                {folderBusy ? (
                  <Loader2 className="animate-spin" />
                ) : (
                  <FolderPlus />
                )}{" "}
                {renamingFolder ? "저장" : "폴더 만들기"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
      <Dialog
        open={movingDocs.length > 0}
        onOpenChange={(open) => {
          if (!open && !moving) setMovingDocs([])
        }}
      >
        <DialogContent className="sm:max-w-md">
          <form onSubmit={(event) => void moveDoc(event)} className="space-y-5">
            <DialogHeader>
              <DialogTitle>교안 이동</DialogTitle>
              <DialogDescription className="break-words">
                {movingDocs.length === 1
                  ? movingDocs[0].name
                  : `${movingDocs.length}개의 교안`}
              </DialogDescription>
            </DialogHeader>
            <div className="space-y-2">
              <Label htmlFor="move-folder">과목 폴더</Label>
              <FolderSelect
                id="move-folder"
                folders={folders}
                value={destinationFolder}
                onChange={setDestinationFolder}
                disabled={moving}
              />
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={moving}
                onClick={() => setMovingDocs([])}
              >
                취소
              </Button>
              <Button
                type="submit"
                disabled={
                  moving ||
                  !movingDocs.length ||
                  movingDocs.every(
                    (item) => destinationFolder === (item.folder_id ?? "")
                  )
                }
              >
                {moving ? (
                  <Loader2 className="animate-spin" />
                ) : (
                  <FolderInput />
                )}{" "}
                이동
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
      <Dialog
        open={!!docAction}
        onOpenChange={(open) => {
          if (!open && !docBusy) setDocAction(null)
        }}
      >
        <DialogContent className="sm:max-w-md" showCloseButton={!docBusy}>
          <form
            onSubmit={(event) => void submitDocAction(event)}
            className="space-y-5"
          >
            <DialogHeader>
              <DialogTitle>
                {docAction?.kind === "delete"
                  ? "교안을 삭제할까요?"
                  : "교안 이름 변경"}
              </DialogTitle>
              <DialogDescription className="break-words">
                {docAction?.kind === "delete"
                  ? `‘${docAction.doc.name}’ 교안과 저장된 번역·질문이 삭제됩니다. 이 작업은 되돌릴 수 없습니다.`
                  : "목록과 읽기 화면에 표시할 이름을 입력하세요."}
              </DialogDescription>
            </DialogHeader>
            {docAction?.kind === "rename" && (
              <div className="space-y-2">
                <Label htmlFor="doc-name">교안 이름</Label>
                <Input
                  id="doc-name"
                  value={docName}
                  onChange={(event) => setDocName(event.target.value)}
                  maxLength={200}
                  required
                  disabled={docBusy}
                />
              </div>
            )}
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={docBusy}
                onClick={() => setDocAction(null)}
              >
                취소
              </Button>
              <Button
                type="submit"
                variant={
                  docAction?.kind === "delete" ? "destructive" : "default"
                }
                disabled={
                  docBusy ||
                  (docAction?.kind === "rename" &&
                    (!docName.trim() || docName.trim() === docAction.doc.name))
                }
              >
                {docBusy ? (
                  <Loader2 className="animate-spin" />
                ) : docAction?.kind === "delete" ? (
                  <Trash2 />
                ) : (
                  <Pencil />
                )}
                {docAction?.kind === "delete" ? "삭제" : "저장"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
      <Dialog
        open={!!deletingItems}
        onOpenChange={(open) => {
          if (!open && !docBusy) setDeletingItems(null)
        }}
      >
        <DialogContent className="sm:max-w-md" showCloseButton={!docBusy}>
          <DialogHeader>
            <DialogTitle>선택한 항목을 삭제할까요?</DialogTitle>
            <DialogDescription>
              교안 {deletingItems?.docIds.length ?? 0}개, 폴더{" "}
              {deletingItems?.folderIds.length ?? 0}개를 삭제합니다. 폴더 안의
              교안과 저장된 번역·질문도 함께 삭제됩니다. 이 작업은 되돌릴 수
              없습니다.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              disabled={docBusy}
              onClick={() => setDeletingItems(null)}
            >
              취소
            </Button>
            <Button
              variant="destructive"
              disabled={docBusy}
              onClick={() => void removeLibraryItems()}
            >
              {docBusy ? <Loader2 className="animate-spin" /> : <Trash2 />}삭제
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog open={exportConfirm} onOpenChange={setExportConfirm}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>진행 중인 번역이 있어요</DialogTitle>
            <DialogDescription>
              아직 {pendingCount}건이 처리 중입니다. 완료된 내용만 PDF로
              내보낼까요?
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setExportConfirm(false)}>
              기다리기
            </Button>
            <Button onClick={() => void exportPdf()}>
              완료된 내용 내보내기
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Toaster theme={theme} richColors position="bottom-right" />
    </SidebarProvider>
  )
}
export default App
