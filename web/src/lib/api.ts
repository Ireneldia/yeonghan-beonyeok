export async function api<T>(
  url: string,
  options: RequestInit = {}
): Promise<T> {
  const headers = new Headers(options.headers)
  if (options.body && !(options.body instanceof FormData))
    headers.set("Content-Type", "application/json")
  const response = await fetch(url, { ...options, headers })
  if (!response.ok) {
    const body = await response.json().catch(() => null)
    throw new Error(
      typeof body?.detail === "string"
        ? body.detail
        : `요청을 완료하지 못했습니다 (${response.status})`
    )
  }
  return response.json() as Promise<T>
}
