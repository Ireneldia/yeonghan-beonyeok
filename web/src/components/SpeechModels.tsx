import { useCallback, useEffect, useRef, useState } from 'react'
import { Check, CircleAlert, Download as DownloadIcon, LoaderCircle, Mic, RefreshCw, Search, Trash2, X } from 'lucide-react'
import { toast } from 'sonner'
import { api } from '@/lib/api'
import type { Download, Fit, SpeechSettings } from '@/lib/types'
import { FitDot } from '@/components/FitDot'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Progress } from '@/components/ui/progress'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Switch } from '@/components/ui/switch'

type SpeechModel = { id: string; name: string; engine: string | null; size: number | null; languages: string[]; installed: boolean; supported: boolean; protected?: boolean; reason?: string; fit?: Fit }
type Status = { state: string; model: string; error?: string; engine?: string; gpu?: boolean | string }
type Props = { open: boolean; onSettingsChange?: () => void | Promise<void> }
const languages = [{ id: 'auto', name: '자동 감지' }, { id: 'ko', name: '한국어' }, { id: 'en', name: '영어' }]
const engines: Record<string, string> = { 'mlx-qwen3-asr': 'Qwen ASR · MLX', 'mlx-whisper': 'Whisper · MLX', 'faster-whisper': 'Whisper · CPU' }
function modelName(model: Pick<SpeechModel, 'id' | 'name'>) { return model.name === model.id ? model.id.split('/').pop() || model.id : model.name || model.id }
function modelLanguages(values: string[]) { return languages.filter(language => language.id !== 'auto' && values.includes(language.id)).map(language => language.name).join('·') }
function bytes(value: number | null | undefined) {
  if (value == null) return '용량 미확인'
  const amount = Math.max(0, value), unit = Math.min(3, Math.floor(Math.log2(amount || 1) / 10))
  return `${(amount / 1024 ** unit).toFixed(unit ? 1 : 0)} ${['B', 'KiB', 'MiB', 'GiB'][unit]}`
}
const message = (error: unknown) => error instanceof Error ? error.message : String(error)

export function SpeechModels({ open, onSettingsChange }: Props) {
  const [settings, setSettings] = useState<SpeechSettings | null>(null)
  const [installed, setInstalled] = useState<SpeechModel[]>([])
  const [catalog, setCatalog] = useState<SpeechModel[]>([])
  const [runtime, setRuntime] = useState<Status | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [query, setQuery] = useState('')
  const [searching, setSearching] = useState(false)
  const [dataError, setDataError] = useState('')
  const [searchError, setSearchError] = useState('')
  const [statusError, setStatusError] = useState('')
  const [deleteTarget, setDeleteTarget] = useState<SpeechModel | null>(null)
  const [download, setDownload] = useState<Download>({ state: 'idle' })
  const [clearing, setClearing] = useState(false)
  const [pollRevision, setPollRevision] = useState(0)
  const downloadSequence = useRef(0)
  const guard = useRef({ revision: 0, mutating: false })
  const searchRevision = useRef({ revision: 0 })
  const lastDownload = useRef<Download>({ state: 'idle' })
  const changed = useRef(onSettingsChange)
  useEffect(() => { changed.current = onSettingsChange }, [onSettingsChange])
  const notify = useCallback(() => {
    void Promise.resolve().then(() => changed.current?.()).catch(error => toast.error(`음성 설정 갱신 실패: ${message(error)}`))
  }, [])

  const refreshData = useCallback(async () => {
    const current = guard.current
    if (current.mutating) return
    const request = ++current.revision
    const results = await Promise.allSettled([
      api<SpeechSettings>('/api/stt/settings'), api<{ models: SpeechModel[] }>('/api/stt/installed'), api<Status>('/api/stt/status'),
    ])
    if (request !== current.revision) return
    const [saved, local, status] = results
    if (saved.status === 'fulfilled') setSettings(saved.value)
    if (local.status === 'fulfilled') setInstalled(local.value.models)
    if (status.status === 'fulfilled') setRuntime(status.value)
    setDataError(results.filter(result => result.status === 'rejected').map(result => message(result.reason)).join(' · '))
    setLoading(false)
  }, [])

  const searchModels = useCallback(async (value: string) => {
    const current = searchRevision.current, request = ++current.revision
    setSearching(true); setSearchError('')
    try {
      const result = await api<{ models: SpeechModel[] }>(`/api/stt/models?q=${encodeURIComponent(value.trim())}`)
      if (request === current.revision) setCatalog(result.models)
    } catch (error) { if (request === current.revision) setSearchError(message(error)) }
    finally { if (request === current.revision) setSearching(false) }
  }, [])

  useEffect(() => {
    if (!open) return
    const current = guard.current, searches = searchRevision.current
    // Opening the panel synchronizes it with the persisted ASR settings and catalog.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void refreshData()
    void searchModels('')
    return () => { current.revision++; searches.revision++ }
  }, [open, refreshData, searchModels])

  const receiveDownload = useCallback((next: Download) => {
    const before = lastDownload.current
    lastDownload.current = next; setDownload(next)
    if (next.state === 'done' && (before.state !== 'done' || before.model !== next.model)) {
      void refreshData(); notify()
    }
  }, [refreshData, notify])

  useEffect(() => {
    if (!open) return
    const controller = new AbortController()
    let timer: ReturnType<typeof setTimeout> | undefined
    async function poll() {
      const request = downloadSequence.current
      try {
        const next = await api<Download>('/api/stt/download', { signal: controller.signal })
        if (controller.signal.aborted || request !== downloadSequence.current) return
        receiveDownload(next); setStatusError('')
        if (next.state === 'downloading') timer = setTimeout(poll, 1000)
      } catch (error) { if (!controller.signal.aborted) setStatusError(message(error)) }
    }
    void poll()
    return () => { controller.abort(); clearTimeout(timer) }
  }, [open, pollRevision, receiveDownload])

  async function saveSettings(next: SpeechSettings) {
    if (guard.current.mutating) return
    const selected = installed.find(model => model.id === next.model)
    if (next.model && (!selected?.installed || !selected.supported)) { toast.error('설치된 지원 모델을 먼저 선택하세요.'); return }
    guard.current.mutating = true; guard.current.revision++; setBusy(true)
    let saved = false
    try {
      const result = await api<SpeechSettings>('/api/stt/settings', { method: 'PUT', body: JSON.stringify(next) })
      setSettings(result); saved = true; notify()
    } catch (error) { toast.error(`음성 설정 저장 실패: ${message(error)}`) }
    finally { guard.current.mutating = false; setBusy(false) }
    if (saved) await refreshData()
  }

  async function startDownload(model: SpeechModel) {
    if (!model.supported || model.installed || installed.some(item => item.id === model.id && item.installed) || busy || clearing || download.state === 'downloading') return
    setBusy(true); setStatusError(''); lastDownload.current = { state: 'idle' }
    downloadSequence.current++
    try { receiveDownload(await api<Download>('/api/stt/download', { method: 'POST', body: JSON.stringify({ model: model.id }) })) }
    catch (error) { toast.error(`다운로드 시작 실패: ${message(error)}`) }
    finally { setBusy(false); setPollRevision(value => value + 1) }
  }

  async function removeModel() {
    if (!deleteTarget || deleteTarget.protected || !settings || deleteTarget.id === settings.model || guard.current.mutating || busy) return
    const target = deleteTarget
    guard.current.mutating = true; guard.current.revision++; setBusy(true)
    let removed = false
    try {
      await api('/api/stt/installed', { method: 'DELETE', body: JSON.stringify({ model: target.id }) })
      setInstalled(rows => rows.filter(model => model.id !== target.id))
      setCatalog(rows => rows.map(model => model.id === target.id ? { ...model, installed: false } : model))
      setDeleteTarget(null); removed = true; toast.success('음성 인식 모델을 삭제했습니다'); notify()
    } catch (error) { toast.error(`모델 삭제 실패: ${message(error)}`) }
    finally { guard.current.mutating = false; setBusy(false) }
    if (removed) await refreshData()
  }

  async function clearDownload() {
    if (clearing || busy || !download.model || !['done', 'error'].includes(download.state)) return
    setClearing(true); downloadSequence.current++
    try {
      receiveDownload(await api<Download>('/api/stt/download', { method: 'DELETE', body: JSON.stringify({ model: download.model }) }))
      setStatusError('')
    } catch (error) { toast.error(`다운로드 카드 닫기 실패: ${message(error)}`) }
    finally { setClearing(false); setPollRevision(value => value + 1) }
  }

  const selected = installed.find(model => model.id === settings?.model)
  const usable = !!selected?.installed && selected.supported
  const knownTotal = !!download.total && download.total_known !== false
  const percent = download.state === 'done' ? 100 : knownTotal ? Math.max(0, Math.min(100, download.percent || 0)) : null
  const downloadStage = download.state === 'done' ? '다운로드 완료' : download.state === 'error' ? '다운로드 실패' : download.status === '모델 정보 확인 중' ? '모델 정보 확인 중' : '모델 파일 받는 중'
  const visibleInstalled = installed.filter(model => download.state !== 'downloading' || model.id !== download.model)
  const downloadCard = download.state !== 'idle' && <div className="space-y-3 rounded-xl border bg-muted/40 p-4" aria-live="polite">
    <div className="flex items-center justify-between gap-2"><p className="flex items-center gap-2 text-sm font-medium">{download.state === 'done' ? <Check className="size-4 text-emerald-600" /> : download.state === 'error' ? <CircleAlert className="size-4 text-destructive" /> : <LoaderCircle className="size-4 animate-spin text-primary" />}{downloadStage}</p>{['done', 'error'].includes(download.state) && <Button variant="ghost" size="icon-xs" aria-label="음성 다운로드 진행 카드 닫기" title="카드만 닫기" disabled={clearing || busy} onClick={() => void clearDownload()}>{clearing ? <LoaderCircle className="animate-spin" /> : <X />}</Button>}</div>
    <p className="break-all text-xs text-muted-foreground">{download.model}</p>
    {download.state !== 'error' && <Progress value={percent} aria-label="음성 모델 다운로드 진행률" className="**:data-[indeterminate]:data-[slot=progress-indicator]:w-1/3 **:data-[indeterminate]:data-[slot=progress-indicator]:animate-pulse" />}
    <div className="flex flex-wrap justify-between gap-2 text-xs tabular-nums text-muted-foreground"><span>{bytes(download.completed || 0)} / {download.total ? `${bytes(download.total)}${download.total_known === false ? ' (확인된 용량)' : ''}` : '전체 용량 확인 중'}</span>{percent !== null && <span>{percent.toFixed(1)}%</span>}</div>
    {download.state === 'error' && <p role="alert" className="text-xs text-destructive">{download.error || '다시 시도해 주세요.'}</p>}
  </div>

  return (
    <div className="space-y-6 px-6 pb-6">
      <section className="space-y-4" aria-label="질문 받아쓰기 설정">
        <div className="flex items-center justify-between"><div><h3 className="flex items-center gap-2 text-sm font-semibold"><Mic className="size-4 text-primary" />질문 받아쓰기</h3><p className="mt-1 text-xs text-muted-foreground">영어 읽기는 브라우저 음성 인식을 사용합니다.</p></div><Button variant="ghost" size="icon-sm" disabled={loading || busy} aria-label="음성 모델과 설정 새로고침" onClick={() => { setLoading(true); void refreshData(); setPollRevision(value => value + 1) }}><RefreshCw className={loading ? 'animate-spin' : ''} /></Button></div>
        {dataError && <p role="alert" className="text-xs text-destructive">{dataError}</p>}
        <div className="space-y-2"><Label htmlFor="speech-model" className="text-xs text-muted-foreground">음성 인식 모델</Label>
          <Select value={settings?.model || '__none__'} disabled={!settings || busy || loading} onValueChange={value => { if (value && settings) void saveSettings({ ...settings, model: value === '__none__' ? '' : value }) }}>
            <SelectTrigger id="speech-model" className="h-10 w-full"><SelectValue>{settings?.model ? <><span className="truncate">{modelName(selected || { id: settings.model, name: settings.model })}</span><FitDot fit={selected?.fit} /></> : settings ? '선택 안 함' : '불러오는 중…'}</SelectValue></SelectTrigger>
            <SelectContent alignItemWithTrigger={false}><SelectItem value="__none__">선택 안 함</SelectItem>{installed.map(model => <SelectItem key={model.id} value={model.id} disabled={!model.installed || !model.supported}><span className="truncate">{modelName(model)}</span><FitDot fit={model.fit} />{!model.supported && <span className="text-xs text-muted-foreground">지원 안 함</span>}</SelectItem>)}</SelectContent>
          </Select>
          {!loading && !usable && <p className="text-xs text-muted-foreground">아래에서 모델을 설치한 뒤 선택해 주세요.</p>}
        </div>
        <div className="space-y-2"><Label htmlFor="speech-language" className="text-xs text-muted-foreground">받아쓰기 언어</Label><Select value={settings?.language || 'auto'} disabled={!settings || !usable || busy || loading} onValueChange={value => { if (value && settings) void saveSettings({ ...settings, language: value as SpeechSettings['language'] }) }}><SelectTrigger id="speech-language" className="h-10 w-full"><SelectValue>{languages.find(language => language.id === (settings?.language || 'auto'))?.name}</SelectValue></SelectTrigger><SelectContent alignItemWithTrigger={false}>{languages.map(language => <SelectItem key={language.id} value={language.id}>{language.name}</SelectItem>)}</SelectContent></Select></div>
        <div className="flex items-center justify-between"><Label htmlFor="speech-hints" className="text-sm">교안 용어 힌트</Label><Switch id="speech-hints" checked={!!settings?.term_hints} disabled={!settings || !usable || busy || loading} onCheckedChange={checked => { if (settings) void saveSettings({ ...settings, term_hints: checked }) }} /></div>
        {runtime?.error ? <p role="status" className="text-xs text-destructive">{runtime.error}</p> : runtime?.state === 'loading' ? <p role="status" className="text-xs text-muted-foreground">음성 모델을 준비하는 중…</p> : null}
      </section>

      <section className="space-y-3 border-t pt-5" aria-label="설치된 음성 인식 모델">
        <h3 className="text-sm font-semibold">설치된 모델 <span className="ml-1 font-normal text-muted-foreground">{installed.length}</span></h3>
        {downloadCard}
        {statusError && <p role="alert" className="text-xs text-destructive">진행 확인 실패: {statusError}</p>}
        {visibleInstalled.map(model => <div key={model.id} className="flex items-center gap-3 rounded-xl border p-3"><FitDot fit={model.fit} /><div className="min-w-0 flex-1"><p className="truncate text-sm font-medium" title={model.id}>{modelName(model)}</p><p className="mt-0.5 text-xs text-muted-foreground">{[engines[model.engine || ''] || '지원 안 함', bytes(model.size), modelLanguages(model.languages), model.id === settings?.model && '선택됨'].filter(Boolean).join(' · ')}</p></div><Button variant="ghost" size="icon-sm" aria-label={`${modelName(model)} 음성 모델 삭제`} title={model.protected ? '기본 모델은 삭제할 수 없습니다.' : undefined} disabled={model.protected || !settings || busy || loading || model.id === settings.model || (download.state === 'downloading' && download.model === model.id)} onClick={() => setDeleteTarget(model)}><Trash2 className="size-4 text-muted-foreground" /></Button></div>)}
        {!installed.length && !loading && download.state !== 'downloading' && <p className="text-sm text-muted-foreground">설치된 음성 모델이 없습니다.</p>}
      </section>

      <section className="space-y-4 border-t pt-5" aria-label="음성 인식 모델 다운로드">
        <h3 className="text-sm font-semibold">모델 다운로드</h3>
        <form className="flex gap-2" onSubmit={event => { event.preventDefault(); void searchModels(query) }}><div className="relative min-w-0 flex-1"><Search className="pointer-events-none absolute left-3 top-3 size-4 text-muted-foreground" /><Input className="h-10 pl-9" aria-label="Hugging Face 음성 모델 검색" placeholder="모델 검색, 예: Qwen3-ASR" value={query} disabled={searching} onChange={event => setQuery(event.target.value)} /></div><Button type="submit" className="h-10 px-4" disabled={searching}>{searching ? <LoaderCircle className="animate-spin" /> : '검색'}</Button></form>
        {searchError && <p role="alert" className="text-xs text-destructive">{searchError}</p>}
        {catalog.map(model => {
          const present = installed.some(item => item.id === model.id && item.installed) || model.installed
          return <div key={model.id} className="flex items-center gap-3 rounded-xl border p-3"><FitDot fit={model.fit} /><div className="min-w-0 flex-1"><p className="truncate text-sm font-medium" title={model.id}>{modelName(model)}</p><p className="mt-1 break-all text-[11px] text-muted-foreground">{model.id}</p><p className="mt-0.5 text-xs text-muted-foreground">{[engines[model.engine || ''] || '지원 안 함', bytes(model.size), modelLanguages(model.languages)].filter(Boolean).join(' · ')}</p></div>{present ? <span className="flex shrink-0 items-center gap-1 text-xs text-muted-foreground"><Check className="size-3.5" />설치됨</span> : <Button variant="outline" size="sm" disabled={!model.supported || busy || clearing || download.state === 'downloading'} title={!model.supported ? model.reason : undefined} aria-label={`${modelName(model)} 다운로드`} onClick={() => void startDownload(model)}>{model.supported ? <><DownloadIcon className="size-3.5" />설치</> : '지원 안 함'}</Button>}</div>
        })}
        {!catalog.length && !searching && !searchError && <p className="text-sm text-muted-foreground">검색 결과가 없습니다.</p>}
      </section>

      <Dialog open={!!deleteTarget} onOpenChange={value => { if (!value && !busy) setDeleteTarget(null) }}><DialogContent showCloseButton={!busy}><DialogHeader><DialogTitle>음성 모델을 삭제할까요?</DialogTitle><DialogDescription>{deleteTarget?.name} 모델을 이 Mac에서 삭제합니다.</DialogDescription></DialogHeader><DialogFooter><Button variant="outline" disabled={busy} onClick={() => setDeleteTarget(null)}>취소</Button><Button variant="destructive" disabled={busy || deleteTarget?.protected || !settings || deleteTarget?.id === settings.model} onClick={() => void removeModel()}>{busy ? <LoaderCircle className="animate-spin" /> : <Trash2 />}삭제</Button></DialogFooter></DialogContent></Dialog>
    </div>
  )
}
