import type { ReactNode, SyntheticEvent } from "react"
import { Ellipsis, FolderInput, FolderOpen, Pencil, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from "@/components/ui/context-menu"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"

type Actions = {
  label: string
  selectionCount: number
  onOpen: () => void
  onRename: () => void
  onMove?: () => void
  onDelete: () => void
  disabled?: boolean
}
type Props = Actions & {
  children: ReactNode
  view: "grid" | "list"
  onSelect?: () => void
  showActions?: boolean
  dropFolderId?: string
}

const stop = (event: SyntheticEvent) => event.stopPropagation()
const boundary = { "data-selection-ignore": true, onPointerDown: stop, onClick: stop, onDoubleClick: stop, onKeyDown: stop }

function MenuItems({ mode, selectionCount, onOpen, onRename, onMove, onDelete, disabled }: Actions & { mode: "context" | "dropdown" }) {
  const Item = mode === "context" ? ContextMenuItem : DropdownMenuItem
  const Separator = mode === "context" ? ContextMenuSeparator : DropdownMenuSeparator
  const inactive = disabled || selectionCount < 1
  return <>
    {selectionCount === 1 && <>
      <Item disabled={inactive} onClick={onOpen}><FolderOpen aria-hidden="true" />열기</Item>
      <Item disabled={inactive} onClick={onRename}><Pencil aria-hidden="true" />이름 변경</Item>
    </>}
    {onMove && <Item disabled={inactive} onClick={onMove}><FolderInput aria-hidden="true" />이동</Item>}
    {(selectionCount === 1 || onMove) && <Separator />}
    <Item disabled={inactive} variant="destructive" onClick={onDelete}><Trash2 aria-hidden="true" />{selectionCount > 1 ? "선택한 항목 삭제" : "삭제"}</Item>
  </>
}

export function LibraryItemMenu({ children, view, onSelect, showActions = true, dropFolderId, ...actions }: Props) {
  const name = actions.selectionCount > 1 ? `선택한 ${actions.selectionCount}개 항목 메뉴` : `${actions.label} 메뉴`
  return (
    <div className="relative min-w-0" data-folder-drop={dropFolderId}>
      <ContextMenu onOpenChange={(open, details) => { if (open && actions.disabled) details.cancel() }}>
        <ContextMenuTrigger onContextMenu={(event) => {
          event.stopPropagation()
          if (actions.disabled) { event.preventDefault(); return }
          onSelect?.()
        }}>
          {children}
        </ContextMenuTrigger>
        <ContextMenuContent className="w-44" aria-label={name} {...boundary}>
          <MenuItems {...actions} mode="context" />
        </ContextMenuContent>
      </ContextMenu>
      {showActions && <div className={`absolute right-2 flex ${view === "list" ? "top-1/2 -translate-y-1/2" : "top-2"}`} {...boundary}>
        <DropdownMenu onOpenChange={(open) => { if (open && !actions.disabled) onSelect?.() }}>
          <DropdownMenuTrigger render={<Button variant="ghost" size="icon-sm" />} aria-label={`${actions.label} 메뉴`} disabled={actions.disabled} {...boundary}>
            <Ellipsis aria-hidden="true" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-44" aria-label={name} {...boundary}>
            <MenuItems {...actions} mode="dropdown" />
          </DropdownMenuContent>
        </DropdownMenu>
      </div>}
    </div>
  )
}
