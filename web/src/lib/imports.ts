export const DEFAULT_IMPORT_EXTENSIONS = [".pdf"]

export function isDocumentFile(
  file: Pick<File, "name">,
  extensions = DEFAULT_IMPORT_EXTENSIONS
) {
  const extension = file.name.slice(file.name.lastIndexOf(".")).toLowerCase()
  return extensions.includes(extension)
}

export function isFileDrag(transfer: Pick<DataTransfer, "types"> | null) {
  return Array.from(transfer?.types ?? []).includes("Files")
}

export function dropFolder(
  target: Element | null,
  currentFolder: string | null
): string | null {
  const explicit = target
    ?.closest("[data-folder-drop]")
    ?.getAttribute("data-folder-drop")
  return explicit == null ? currentFolder : explicit || null
}
