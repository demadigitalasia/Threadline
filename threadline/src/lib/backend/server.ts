import { cookies } from "next/headers";

export async function getBackendUser() {
  const cookieStore = await cookies();
  const base = process.env.THREADLINE_API_URL ?? "http://localhost:3001";
  try {
    const response = await fetch(`${base}/v1/auth/session`, {
      headers: { cookie: cookieStore.getAll().map(({ name, value }) => `${name}=${value}`).join("; ") },
      cache: "no-store",
    });
    if (!response.ok) return null;
    const result = await response.json() as { user: unknown };
    return result.user;
  } catch { return null; }
}

export async function callBackend(path: string, request: Request, body?: unknown) {
  const base = process.env.THREADLINE_API_URL ?? "http://localhost:3001";
  const headers = new Headers({ accept: "application/json", cookie: request.headers.get("cookie") ?? "" });
  if (body !== undefined) headers.set("content-type", "application/json");
  return fetch(`${base}/v1/${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: "no-store",
  });
}
