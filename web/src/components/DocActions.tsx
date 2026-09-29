import { Ellipsis, FolderInput, Pencil, Trash2 } from "lucide-react"
import type { Doc } from "@/lib/types"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"

type Props = {
  doc: Doc
  onRename: (doc: Doc) => void
  onMove: (doc: Doc) => void
  onDelete: (doc: Doc) => void
  disabled?: boolean
}

export function DocActions({ doc, onRename, onMove, onDelete, disabled }: Props) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={<Button variant="ghost" size="icon-sm" />}
        aria-label={`${doc.name} 관리`}
        disabled={disabled}
        onClick={(event) => event.stopPropagation()}
      >
        <Ellipsis aria-hidden="true" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-44" aria-label={`${doc.name} 관리 메뉴`} onClick={(event) => event.stopPropagation()}>
        <DropdownMenuItem disabled={disabled} onClick={() => onRename(doc)}><Pencil aria-hidden="true" />이름 변경</DropdownMenuItem>
        <DropdownMenuItem disabled={disabled} onClick={() => onMove(doc)}><FolderInput aria-hidden="true" />이동</DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem disabled={disabled} variant="destructive" onClick={() => onDelete(doc)}><Trash2 aria-hidden="true" />삭제</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
