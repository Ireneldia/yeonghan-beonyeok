import { useState } from 'react'
import { Cpu, Download, RefreshCw, SlidersHorizontal, Zap } from 'lucide-react'
import type { Models, Provider, Settings } from '@/lib/types'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Switch } from '@/components/ui/switch'
import { FitDot } from '@/components/FitDot'

type Props = {
  settings: Settings | null
  models: Models | null
  busy: boolean
  onChange: (next: Settings) => Promise<void>
  onRefresh: () => Promise<void>
  onOpenDownloads: () => void
}

const providers: { id: Provider; name: string }[] = [
  { id: 'codex', name: 'Codex' },
  { id: 'claude', name: 'Claude Code' },
  { id: 'local', name: '로컬' },
]

export function ModelSettings({ settings, models, busy, onChange, onRefresh, onOpenDownloads }: Props) {
  const [saving, setSaving] = useState(false)
  const disabled = busy || saving || !settings
  const provider = settings?.provider || 'codex'
  const current = settings?.[`${provider}_model`] || ''
  const choices = [...(models?.[provider] || [])]
  if (current && !choices.some(model => model.id === current)) choices.unshift({ id: current, name: current, efforts: [] })
  const selected = choices.find(model => model.id === current)
  const capability = models?.[provider].find(model => model.id === current)
  const levels = capability?.efforts || []
  const savedEffort = settings?.[`${provider}_effort`] || ''
  const effort = capability && !levels.some(level => level.id === savedEffort) ? '' : savedEffort
  const effortChoices = [{ id: '__default__', name: '모델 기본' }, ...levels.filter(level => level.id !== '')]
  if (!capability && savedEffort) effortChoices.push({ id: savedEffort, name: savedEffort })
  const problem = models?.errors[provider]
  const gpu = models?.gpu

  async function change(next: Settings) {
    const normalized = { ...next }
    const model = models?.[next.provider].find(item => item.id === next[`${next.provider}_model`])
    if (model) {
      if (!model.efforts.some(level => level.id === next[`${next.provider}_effort`])) normalized[`${next.provider}_effort`] = ''
      if (next.provider === 'codex' && !model.fast) normalized.codex_fast = false
    }
    setSaving(true)
    try { await onChange(normalized) } finally { setSaving(false) }
  }

  return (
    <section className="space-y-5" aria-label="번역 모델 설정">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2 text-sm font-semibold"><SlidersHorizontal className="size-4 text-primary" /> 번역 설정</div>
        <Button variant="ghost" size="icon-sm" disabled={busy || saving} onClick={() => void onRefresh()} aria-label="모델 목록과 상태 새로고침">
          <RefreshCw className={busy ? 'animate-spin' : ''} />
        </Button>
      </div>
      <div className="space-y-2">
        <Label htmlFor="model-provider" className="text-xs text-muted-foreground">연결 방식</Label>
        <Select value={provider} disabled={disabled} onValueChange={value => { if (settings && value) void change({ ...settings, provider: value as Provider }) }}>
          <SelectTrigger id="model-provider" className="h-10 w-full"><SelectValue>{providers.find(item => item.id === provider)?.name}</SelectValue></SelectTrigger>
          <SelectContent alignItemWithTrigger={false}>
            {providers.map(item => <SelectItem key={item.id} value={item.id}>{item.name}</SelectItem>)}
          </SelectContent>
        </Select>
      </div>
      <div className="space-y-2">
        <Label htmlFor="translation-model" className="text-xs text-muted-foreground">모델</Label>
        <Select value={current || null} disabled={disabled || !choices.length} onValueChange={value => { if (settings && value) void change({ ...settings, [`${provider}_model`]: value }) }}>
          <SelectTrigger id="translation-model" className="h-10 w-full"><SelectValue placeholder="모델 불러오는 중…">{selected && <><span className="truncate">{selected.name || selected.id}</span>{provider === 'local' && <FitDot fit={selected.fit} />}</>}</SelectValue></SelectTrigger>
          <SelectContent alignItemWithTrigger={false}>
            {choices.map(model => <SelectItem key={model.id} value={model.id}><span className="truncate">{model.name || model.id}</span>{provider === 'local' && <FitDot fit={model.fit} />}</SelectItem>)}
          </SelectContent>
        </Select>
      </div>
      <div className="space-y-2">
        <Label htmlFor="model-effort" className="text-xs text-muted-foreground">추론 수준</Label>
        <Select value={effort || '__default__'} disabled={disabled || !levels.length} onValueChange={value => { if (settings && value) void change({ ...settings, [`${provider}_effort`]: value === '__default__' ? '' : value }) }}>
          <SelectTrigger id="model-effort" className="h-10 w-full"><SelectValue>{effortChoices.find(level => level.id === (effort || '__default__'))?.name}</SelectValue></SelectTrigger>
          <SelectContent alignItemWithTrigger={false}>{effortChoices.map(level => <SelectItem key={level.id} value={level.id}>{level.name}</SelectItem>)}</SelectContent>
        </Select>
      </div>
      {provider === 'codex' && <div className="flex items-center justify-between rounded-xl border border-border bg-muted/40 p-3 text-foreground">
        <div className="space-y-1"><Label htmlFor="codex-fast" className="gap-1.5"><Zap className="size-3.5 text-primary" /> Fast</Label><p className="text-xs text-muted-foreground">{capability?.fast ? '사용량이 더 소모됩니다' : '이 모델은 Fast 미지원'}</p></div>
        <Switch id="codex-fast" checked={!!settings?.codex_fast} disabled={disabled || !capability?.fast} onCheckedChange={checked => { if (settings) void change({ ...settings, codex_fast: checked }) }} />
      </div>}
      {problem ? <p role="status" className="text-xs leading-relaxed text-rose-600">{problem}</p> : provider === 'local' && <div className="flex items-center gap-2 text-xs text-muted-foreground"><Cpu className="size-3.5" />{gpu?.state === 'gpu' ? 'GPU 사용 확인' : gpu?.state === 'cpu' ? 'CPU로 실행 중' : gpu?.state === 'unavailable' ? '연결 확인 필요' : '모델 대기 중'}</div>}
      <Button variant="outline" className="w-full" onClick={onOpenDownloads}><Download className="size-4" /> 로컬 모델 관리</Button>
    </section>
  )
}
