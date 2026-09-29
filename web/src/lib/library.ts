export const DOCUMENT_DRAG_TYPE = "application/x-yeonghan-documents"

export function isDocumentDrag(transfer: Pick<DataTransfer, "types"> | null) {
  return Array.from(transfer?.types ?? []).includes(DOCUMENT_DRAG_TYPE)
}

export function draggedDocumentIds(
  transfer: Pick<DataTransfer, "getData">
): string[] {
  try {
    const ids: unknown = JSON.parse(transfer.getData(DOCUMENT_DRAG_TYPE))
    if (
      !Array.isArray(ids) ||
      !ids.length ||
      ids.length > 500 ||
      ids.some((id) => typeof id !== "string" || !id || id.length > 200)
    )
      return []
    return [...new Set(ids as string[])]
  } catch {
    return []
  }
}

export type LibrarySelection = { docIds: string[]; folderIds: string[] }
export function splitSelection(keys: string[]): LibrarySelection {
  return {
    docIds: keys
      .filter((key) => key.startsWith("doc:"))
      .map((key) => key.slice(4)),
    folderIds: keys
      .filter((key) => key.startsWith("folder:"))
      .map((key) => key.slice(7)),
  }
}
