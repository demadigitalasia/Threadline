import { NextRequest } from "next/server";

type RouteContext = { params: Promise<{ path: string[] }> };
export const dynamic = "force-dynamic";

function normalizeOrigin(value: string | null | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:" ? url.origin : null;
  } catch {
    return null;
  }
}

function allowedOrigins(request: NextRequest): Set<string> {
  const configured = process.env.THREADLINE_PUBLIC_ORIGINS;
  if (!configured?.trim()) return new Set([request.nextUrl.origin]);
  return new Set(configured.split(",").map((value) => normalizeOrigin(value.trim())).filter((value): value is string => value !== null));
}

async function forward(request: NextRequest, context: RouteContext) {
  const origin = request.headers.get("origin");
  if (origin) {
    const requestOrigin = normalizeOrigin(origin);
    if (!requestOrigin || !allowedOrigins(request).has(requestOrigin)) {
      return Response.json({ code: "ORIGIN_NOT_ALLOWED", message: "Permintaan lintas origin ditolak" }, { status: 403 });
    }
  }
  const base = process.env.THREADLINE_API_URL ?? "http://localhost:3001";
  const { path } = await context.params;
  const route = path.map((segment) => encodeURIComponent(segment)).join("/");
  const url = new URL(`/v1/${route}`, base);
  url.search = request.nextUrl.search;
  const headers = new Headers();
  for (const name of ["accept", "content-type", "cookie", "last-event-id"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  let upstream: Response;
  try {
    upstream = await fetch(url, {
      method: request.method,
      headers,
      body: ["GET", "HEAD"].includes(request.method) ? undefined : await request.arrayBuffer(),
      cache: "no-store",
      redirect: "manual",
      signal: request.signal,
    });
  } catch {
    return Response.json({ message: "API Threadline tidak dapat dihubungi" }, { status: 502 });
  }
  const responseHeaders = new Headers();
  for (const name of ["content-type", "cache-control", "content-disposition", "retry-after"]) {
    const value = upstream.headers.get(name);
    if (value) responseHeaders.set(name, value);
  }
  const cookies = upstream.headers.getSetCookie?.() ?? [];
  for (const cookie of cookies) responseHeaders.append("set-cookie", cookie);
  if (request.nextUrl.pathname.endsWith("/realtime/events")) {
    responseHeaders.set("cache-control", "no-cache, no-transform");
    responseHeaders.set("x-accel-buffering", "no");
  }
  return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
}

export const GET = forward;
export const POST = forward;
export const PUT = forward;
export const PATCH = forward;
export const DELETE = forward;
