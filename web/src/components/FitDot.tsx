import { cn } from '@/lib/utils'
import type { Fit } from '@/lib/types'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'

const fits = {
  green: { color: 'bg-emerald-500', label: '메모리 여유' },
  yellow: { color: 'bg-orange-400', label: '메모리 여유 적음' },
  red: { color: 'bg-rose-500', label: '메모리 부족 예상' },
  unknown: { color: 'border border-slate-300', label: '메모리 정보 없음' },
}

export function FitDot({ fit, className }: { fit?: Fit | null; className?: string }) {
  const { color, label } = fits[fit?.level || 'unknown']
  return (
    <Tooltip>
      <TooltipTrigger render={<span role="img" aria-label={label} className={cn('inline-block size-2 shrink-0 self-center rounded-full align-middle', color, className)} />} />
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  )
}
