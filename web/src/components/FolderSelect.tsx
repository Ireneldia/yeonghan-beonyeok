import type { Folder } from "@/lib/types"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"

export function FolderSelect({
  id,
  folders,
  value,
  onChange,
  disabled,
}: {
  id: string
  folders: Folder[]
  value: string
  onChange: (value: string) => void
  disabled?: boolean
}) {
  return (
    <Select
      value={value}
      onValueChange={(next) => onChange(next ?? "")}
      disabled={disabled}
    >
      <SelectTrigger id={id} className="h-10 w-full">
        <SelectValue>
          {folders.find((folder) => folder.id === value)?.name ??
            "메인 (폴더 없음)"}
        </SelectValue>
      </SelectTrigger>
      <SelectContent alignItemWithTrigger={false}>
        <SelectItem value="">메인 (폴더 없음)</SelectItem>
        {folders.map((folder) => (
          <SelectItem key={folder.id} value={folder.id}>
            {folder.name}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}
