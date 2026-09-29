import { useCallback, useEffect, useRef, useState } from 'react'
import { Check, CircleAlert, Download as DownloadIcon, HardDrive, LoaderCircle, RefreshCw, Search, Trash2, X } from 'lucide-react'
import { toast } from 'sonner'
import { api } from '@/lib/api'
import type { CatalogModel, Download } from '@/lib/types'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Progress } from '@/components/ui/progress'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { FitDot } from '@/components/FitDot'
import { SpeechModels } from '@/components/SpeechModels'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'

type Props = { open: boolean; onOpenChange: (open: boolean) => void; onComplete: () => void | Promise<void>; initialTab?: 'translation' | 'speech'; onSpeechSettingsChange?: () => void | Promise<void> }
type InstalledModel = { id: string; name: string; size: number; digest?: string; cloud?: boolean; fit?: CatalogModel['fit'] }

function bytes(value = 0) {
  const amount = Math.max(0, value), unit = Math.min(3, Math.floor(Math.log2(amount || 1) / 10))
  return `${(amount / 1024 ** unit).toFixed(unit ? 1 : 0)} ${['B', 'KiB', 'MiB', 'GiB'][unit]}`
}

const stages: Record<string, string> = {
  'pulling manifest': '모델 정보 확인 중', 'verifying sha256 digest': '파일 확인 중',
  'writing manifest': '모델 등록 중', 'removing any unused layers': '마무리 중', success: '다운로드 완료',
}

export function ModelDownloads({ open, onOpenChange, onComplete, initialTab = 'translation', onSpeechSettingsChange }: Props) {
  const [tab, setTab] = useState<'translation' | 'speech'>(initialTab)
  const translationOpen = open && tab === 'translation'
  useEffect(() => {
    // Each opening follows the requested panel; user tab changes remain local.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (open) setTab(initialTab)
  }, [open, initialTab])
  const [installed, setInstalled] = useState<InstalledModel[]>([])
  const [installedLoading, setInstalledLoading] = useState(true)
  const [installedError, setInstalledError] = useState('')
  const [deleteTarget, setDeleteTarget] = useState<InstalledModel | null>(null)
  const [removing, setRemoving] = useState(false)
  const [query, setQuery] = useState('')
  const [families, setFamilies] = useState<CatalogModel[]>([])
  const [family, setFamily] = useState('')
  const [tags, setTags] = useState<CatalogModel[]>([])
  const [tag, setTag] = useState('')
  const [busy, setBusy] = useState(false)
  const [searched, setSearched] = useState(false)
  const [searchError, setSearchError] = useState('')
  const [statusError, setStatusError] = useState('')
  const [download, setDownload] = useState<Download>({ state: 'idle' })
  const [clearing, setClearing] = useState(false)
  const [refresh, setRefresh] = useState(0)
  const downloadSequence = useRef(0)
  const previousStatus = useRef<Download>({ state: 'idle' })
  const installedSequence = useRef({ revision: 0 })
  const completed = useRef(onComplete)
  useEffect(() => { completed.current = onComplete }, [onComplete])

  const refreshInstalled = useCallback(async () => {
    const guard = installedSequence.current, request = ++guard.revision
    try {
      const result = await api<{ models: InstalledModel[] }>('/api/llm/local/installed')
      if (request === guard.revision) { setInstalled(result.models); setInstalledError('') }
    } catch (error) {
      if (request === guard.revision) setInstalledError(error instanceof Error ? error.message : '설치된 모델을 확인하지 못했습니다.')
    } finally { if (request === guard.revision) setInstalledLoading(false) }
  }, [])

  useEffect(() => {
    if (!translationOpen) return
    const guard = installedSequence.current
    // State changes only after the inventory request settles.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void refreshInstalled()
    return () => { guard.revision++ }
  }, [translationOpen, refreshInstalled])

  const receiveStatus = useCallback((next: Download) => {
    const before = previousStatus.current
    previousStatus.current = next
    setDownload(next)
    if (next.state === 'done' && (before.state !== 'done' || before.model !== next.model)) {
      void Promise.all([refreshInstalled(), Promise.resolve().then(() => completed.current())]).catch(error => toast.error(`모델 목록 갱신 실패: ${error instanceof Error ? error.message : error}`))
    }
  }, [refreshInstalled])

  async function removeInstalled() {
    if (!deleteTarget || removing || installedLoading) return
    const target = deleteTarget
    setRemoving(true); installedSequence.current.revision++
    try {
      await api<{ ok: boolean }>('/api/llm/local/installed', { method: 'DELETE', body: JSON.stringify({ model: target.id }) })
      setInstalled(rows => rows.filter(model => model.id !== target.id))
      setDeleteTarget(null)
      toast.success(`${target.name || target.id} 모델을 삭제했습니다`)
      await Promise.all([refreshInstalled(), Promise.resolve().then(() => completed.current())]).catch(error => toast.error(`모델 목록 갱신 실패: ${error instanceof Error ? error.message : error}`))
    } catch (error) { toast.error(`모델 삭제 실패: ${error instanceof Error ? error.message : error}`) }
    finally { setRemoving(false) }
  }

  useEffect(() => {
    if (!translationOpen) return
    const controller = new AbortController()
    let timer: ReturnType<typeof setTimeout> | undefined
    async function poll() {
      const request = downloadSequence.current
      try {
        const next = await api<Download>('/api/llm/local/download', { signal: controller.signal })
        if (controller.signal.aborted || request !== downloadSequence.current) return
        receiveStatus(next)
        setStatusError('')
        if (next.state === 'downloading') timer = setTimeout(poll, 1000)
      } catch (error) {
        if (!controller.signal.aborted) setStatusError(error instanceof Error ? error.message : '진행 상태를 확인하지 못했습니다.')
      }
    }
    void poll()
    return () => { controller.abort(); clearTimeout(timer) }
  }, [translationOpen, refresh, receiveStatus])

  async function loadTags(model: string) {
    setFamily(model); setTags([]); setTag(''); setBusy(true); setSearchError('')
    try {
      const result = await api<{ models: CatalogModel[] }>(`/api/llm/local/tags?model=${encodeURIComponent(model)}`)
      setTags(result.models); setTag(result.models[0]?.id || '')
      if (!result.models.length) setSearchError('다운로드할 수 있는 버전이 없습니다.')
    } catch (error) { setSearchError(error instanceof Error ? error.message : '버전을 확인하지 못했습니다.') }
    finally { setBusy(false) }
  }

  async function search() {
    if (!query.trim() || busy) return
    setBusy(true); setSearchError(''); setFamilies([]); setFamily(''); setTags([]); setTag('')
    try {
      const result = await api<{ models: CatalogModel[] }>(`/api/llm/local/search?q=${encodeURIComponent(query.trim())}`)
      setFamilies(result.models); setSearched(true)
      if (result.models.length) await loadTags(result.models[0].id)
    } catch (error) { setSearchError(error instanceof Error ? error.message : '모델을 검색하지 못했습니다.') }
    finally { setBusy(false) }
  }

  async function start() {
    if (!tag || busy || clearing || download.state === 'downloading') return
    setBusy(true); setStatusError('')
    previousStatus.current = { state: 'idle' }
    downloadSequence.current++
    try {
      receiveStatus(await api<Download>('/api/llm/local/download', { method: 'POST', body: JSON.stringify({ model: tag }) }))
    } catch (error) { toast.error(`다운로드 시작 실패: ${error instanceof Error ? error.message : error}`) }
    finally { setBusy(false); setRefresh(value => value + 1) }
  }

  async function clearDownload() {
    if (clearing || busy || !download.model || !['done', 'error'].includes(download.state)) return
    setClearing(true); downloadSequence.current++
    try {
      receiveStatus(await api<Download>('/api/llm/local/download', { method: 'DELETE', body: JSON.stringify({ model: download.model }) }))
      setStatusError('')
    } catch (error) { toast.error(`다운로드 카드 닫기 실패: ${error instanceof Error ? error.message : error}`) }
    finally { setClearing(false); setRefresh(value => value + 1) }
  }

  const selected = tags.find(model => model.id === tag)
  const knownTotal = !!download.total && download.total_known !== false
  const percent = download.state === 'done' ? 100 : knownTotal ? Math.max(0, Math.min(100, download.percent || 0)) : null
  const stage = stages[download.status || ''] || (download.status?.startsWith('pulling ') ? '모델 파일 받는 중' : download.status || '다운로드 중')
  const visibleInstalled = installed.filter(model => download.state !== 'downloading' || model.id !== download.model)
  const downloadCard = download.state !== 'idle' && <div className="space-y-4 rounded-2xl border border-slate-200 bg-slate-50/70 p-4" aria-live="polite">
    <div className="flex items-center justify-between gap-2"><div className="flex items-center gap-2 text-sm font-medium">{download.state === 'done' ? <Check className="size-4 text-emerald-600" /> : download.state === 'error' ? <CircleAlert className="size-4 text-rose-500" /> : <LoaderCircle className="size-4 animate-spin text-indigo-500" />}{download.state === 'done' ? '다운로드 완료' : download.state === 'error' ? '다운로드 실패' : stage}</div>{['done', 'error'].includes(download.state) && <Button variant="ghost" size="icon-xs" aria-label="다운로드 진행 카드 닫기" title="카드만 닫기" disabled={clearing || busy} onClick={() => void clearDownload()}>{clearing ? <LoaderCircle className="animate-spin" /> : <X />}</Button>}</div>
    <p className="break-all text-xs text-muted-foreground">{download.model}</p>
    {download.state !== 'error' && <Progress value={percent} aria-label="모델 다운로드 진행률" className="**:data-[slot=progress-track]:h-1.5 **:data-[indeterminate]:data-[slot=progress-indicator]:w-1/3 **:data-[indeterminate]:data-[slot=progress-indicator]:animate-pulse" />}
    <div className="flex flex-wrap items-center justify-between gap-2 text-xs tabular-nums text-muted-foreground"><span>{bytes(download.completed)} / {download.total ? `${bytes(download.total)}${download.total_known === false ? ' (확인된 용량)' : ''}` : '전체 용량 확인 중'}</span>{percent !== null && <span>{percent.toFixed(1)}%</span>}</div>
    {download.state === 'done' && <p className="text-xs text-emerald-700">번역 설정에서 이 모델을 선택할 수 있습니다.</p>}
    {download.state === 'error' && <p role="alert" className="text-xs leading-relaxed text-rose-600">{download.error || download.status || '다시 시도해 주세요.'}</p>}
  </div>

  return (
    <Sheet open={open} onOpenChange={value => { if (!value && !removing) setDeleteTarget(null); onOpenChange(value) }}>
      <SheetContent className="gap-0 data-[side=right]:w-full data-[side=right]:sm:max-w-[460px]">
        <SheetHeader className="border-b px-6 pb-5 pt-7">
          <div className="mb-3 flex size-10 items-center justify-center rounded-xl bg-indigo-50 text-indigo-600"><HardDrive className="size-5" /></div>
          <SheetTitle className="text-lg font-semibold">모델 관리</SheetTitle>
          <SheetDescription className="mt-1 text-sm">설치된 모델을 관리하고 새 모델을 추가하세요.</SheetDescription>
        </SheetHeader>
        <Tabs value={tab} onValueChange={value => setTab(value as 'translation' | 'speech')} className="min-h-0 flex-1 gap-0">
          <div className="px-6 py-4"><TabsList className="w-full"><TabsTrigger value="translation">번역 모델</TabsTrigger><TabsTrigger value="speech">음성 인식</TabsTrigger></TabsList></div>
          <TabsContent value="translation" className="min-h-0 overflow-y-auto"><div className="space-y-6 px-6 pb-6">
          <section className="space-y-3" aria-label="설치된 로컬 모델">
            <div className="flex items-center justify-between"><h3 className="text-sm font-semibold">설치된 모델 <span className="ml-1 font-normal text-muted-foreground">{installed.length}</span></h3><Button variant="ghost" size="icon-sm" aria-label="설치된 모델 새로고침" disabled={installedLoading || removing} onClick={() => { setInstalledLoading(true); void refreshInstalled() }}><RefreshCw className={installedLoading ? 'animate-spin' : ''} /></Button></div>
            {downloadCard}
            {statusError && <div className="flex items-start gap-2 rounded-xl bg-rose-50 p-3 text-xs text-rose-700"><CircleAlert className="mt-0.5 size-4 shrink-0" /><p className="flex-1">진행 확인 실패: {statusError}</p><Button variant="ghost" size="icon-xs" aria-label="다운로드 상태 다시 확인" onClick={() => setRefresh(value => value + 1)}><RefreshCw /></Button></div>}
            {installedError && <p role="alert" className="text-xs leading-relaxed text-rose-600">{installedError}</p>}
            {installedLoading && !installed.length ? <p role="status" className="py-4 text-center text-sm text-muted-foreground">설치된 모델 확인 중…</p> : visibleInstalled.length ? <div className="max-h-64 space-y-2 overflow-y-auto">
              {visibleInstalled.map(model => <div key={model.id} className="flex items-center gap-3 rounded-xl border border-border p-3">
                <FitDot fit={model.cloud ? undefined : model.fit} />
                <div className="min-w-0 flex-1"><p className="truncate text-sm font-medium" title={model.id}>{model.name || model.id}</p><p className="mt-0.5 text-xs tabular-nums text-muted-foreground">{bytes(model.size)}</p></div>
                <Button variant="ghost" size="icon-sm" aria-label={`${model.name || model.id} 모델 삭제`} disabled={removing || installedLoading || (download.state === 'downloading' && download.model === model.id)} onClick={() => setDeleteTarget(model)}><Trash2 className="size-4 text-muted-foreground" /></Button>
              </div>)}
            </div> : !installedError && download.state !== 'downloading' && <p className="rounded-xl border border-dashed px-4 py-5 text-center text-sm text-muted-foreground">설치된 모델이 없습니다.</p>}
          </section>
          <div className="border-t pt-5"><h3 className="text-sm font-semibold">새 모델 다운로드</h3></div>
          <form className="flex gap-2" onSubmit={event => { event.preventDefault(); void search() }}>
            <div className="relative min-w-0 flex-1"><Search className="pointer-events-none absolute left-3 top-3 size-4 text-muted-foreground" /><Input value={query} onChange={event => setQuery(event.target.value)} disabled={busy} aria-label="로컬 모델 검색" placeholder="모델 검색, 예: qwen3.5" className="h-10 pl-9" /></div>
            <Button type="submit" className="h-10 px-4" disabled={busy || !query.trim()}>{busy ? <LoaderCircle className="animate-spin" /> : '검색'}</Button>
          </form>
          {families.length > 0 && <div className="space-y-5">
            <div className="space-y-2"><Label htmlFor="download-family" className="text-xs text-muted-foreground">모델</Label>
              <Select value={family || null} disabled={busy} onValueChange={value => { if (value) void loadTags(value) }}>
                <SelectTrigger id="download-family" className="h-10 w-full"><SelectValue>{families.find(model => model.id === family)?.name || family}</SelectValue></SelectTrigger>
                <SelectContent alignItemWithTrigger={false}>{families.map(model => <SelectItem key={model.id} value={model.id}>{model.name || model.id}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div className="space-y-2"><Label htmlFor="download-version" className="text-xs text-muted-foreground">버전</Label>
              <Select value={tag || null} disabled={busy || !tags.length} onValueChange={value => { if (value) setTag(value) }}>
                <SelectTrigger id="download-version" className="h-10 w-full"><SelectValue placeholder="버전 확인 중…">{selected && <><span className="truncate">{selected.name || selected.id}</span>{selected.size && <span className="ml-auto text-xs text-muted-foreground">{selected.size}</span>}<FitDot fit={selected.fit} /></>}</SelectValue></SelectTrigger>
                <SelectContent alignItemWithTrigger={false}>{tags.map(model => <SelectItem key={model.id} value={model.id}><span className="truncate">{model.name || model.id}</span>{model.size && <span className="ml-auto text-xs text-muted-foreground">{model.size}</span>}<FitDot fit={model.fit} /></SelectItem>)}</SelectContent>
              </Select>
            </div>
            <Button className="h-10 w-full" disabled={busy || clearing || !tag || download.state === 'downloading'} onClick={() => void start()}><DownloadIcon className="size-4" /> 다운로드</Button>
          </div>}
          {searchError && <p role="alert" className="text-sm text-rose-600">{searchError}</p>}
          {!families.length && !busy && !searchError && <div className="rounded-2xl border border-dashed border-slate-200 px-6 py-12 text-center"><Search className="mx-auto mb-3 size-7 text-slate-300" /><p className="text-sm text-muted-foreground">{searched ? '검색 결과가 없습니다.' : '사용할 모델을 검색해 보세요.'}</p></div>}
          </div></TabsContent>
          <TabsContent value="speech" className="min-h-0 overflow-y-auto"><SpeechModels open={open && tab === 'speech'} onSettingsChange={onSpeechSettingsChange} /></TabsContent>
        </Tabs>
      </SheetContent>
      <Dialog open={!!deleteTarget} onOpenChange={value => { if (!value && !removing) setDeleteTarget(null) }}>
        <DialogContent><DialogHeader><DialogTitle>모델을 삭제할까요?</DialogTitle><DialogDescription><span className="font-medium text-foreground">{deleteTarget?.name || deleteTarget?.id}</span> 모델을 이 Mac에서 삭제합니다. 필요하면 다시 다운로드할 수 있습니다.</DialogDescription></DialogHeader><DialogFooter><Button variant="outline" disabled={removing} onClick={() => setDeleteTarget(null)}>취소</Button><Button variant="destructive" disabled={removing} onClick={() => void removeInstalled()}>{removing ? <LoaderCircle className="animate-spin" /> : <Trash2 />}삭제</Button></DialogFooter></DialogContent>
      </Dialog>
    </Sheet>
  )
}
