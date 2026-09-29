import { Ellipsis, Pencil, Trash2 } from "lucide-react"
import type { Folder } from "@/lib/types"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"

export function FolderActions({
  folder,
  onDelete,
  onRename,
  disabled,
  className,
}: {
  folder: Folder
  onDelete: (folder: Folder) => void
  onRename?: (folder: Folder) => void
  disabled?: boolean
  className?: string
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={<Button variant="ghost" size="icon-sm" className={className} />}
        aria-label={`${folder.name} 폴더 관리`}
        disabled={disabled}
      >
        <Ellipsis aria-hidden="true" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-40">
        {onRename && (
          <DropdownMenuItem
            disabled={disabled}
            onClick={() => onRename(folder)}
          >
            <Pencil aria-hidden="true" />
            이름 변경
          </DropdownMenuItem>
        )}
        <DropdownMenuItem
          variant="destructive"
          disabled={disabled}
          onClick={() => onDelete(folder)}
        >
          <Trash2 aria-hidden="true" />
          폴더 삭제
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
