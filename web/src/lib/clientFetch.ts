export async function readJson<T>(response: Response, fallback?: T): Promise<T> {
  const text = await response.text();
  if (!text.trim()) {
    if (fallback !== undefined) return fallback;
    throw new Error(response.ok ? "服务端返回了空响应，请稍后重试" : `请求失败：${response.status}`);
  }
  try {
    return JSON.parse(text) as T;
  } catch {
    if (!response.ok) throw new Error(text || `请求失败：${response.status}`);
    throw new Error("服务端返回了无法解析的数据，请稍后重试");
  }
}

export async function fetchJson<T>(input: RequestInfo | URL, init?: RequestInit, fallback?: T): Promise<T> {
  const response = await fetch(input, init);
  const data = await readJson<T & { error?: string }>(response, fallback as (T & { error?: string }) | undefined);
  if (!response.ok) throw new Error(data?.error || `请求失败：${response.status}`);
  return data as T;
}
