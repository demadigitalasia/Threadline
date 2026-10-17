"use client";

type ApiError = { message: string; code?: string };
type Result<T = unknown> = { data: T | null; error: ApiError | null };
type AuthUser = { id: string; email?: string | null; email_confirmed_at?: string | null };
type DbRow = Record<string, unknown>;

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`/api/backend/${path}`, {
    ...init,
    credentials: "same-origin",
    cache: "no-store",
    headers: { ...(init?.body instanceof FormData ? {} : { "content-type": "application/json" }), ...init?.headers },
  });
  const result = response.headers.get("content-type")?.includes("application/json") ? await response.json() : null;
  if (!response.ok) {
    const details = result as { message?: string | string[]; code?: string } | null;
    const message = Array.isArray(details?.message) ? details.message.join(", ") : details?.message;
    const error = new Error(message || `Permintaan gagal (${response.status})`) as Error & { code?: string; status?: number };
    error.code = details?.code;
    error.status = response.status;
    throw error;
  }
  return result as T;
}

function resultOf<T>(data: T | null, error: ApiError | null = null): Result<T> { return { data, error }; }
function toApiError(error: unknown): ApiError {
  const e = error as Error & { code?: string };
  return { message: e?.message || "Permintaan gagal", ...(e?.code ? { code: e.code } : {}) };
}
function notifyAuth(event: "SIGNED_IN" | "SIGNED_OUT" | "USER_UPDATED") {
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("threadline:auth", { detail: event }));
}

class QueryBuilder implements PromiseLike<Result<DbRow[]>> {
  private query: Record<string, unknown> = { action: "select" };
  constructor(private readonly table: string) {}

  select(columns = "*") { this.query.columns = columns.split(",").map((column) => column.trim()); return this; }
  eq(column: string, value: unknown) { this.addFilter({ column, operator: "eq", value }); return this; }
  neq(column: string, value: unknown) { this.addFilter({ column, operator: "neq", value }); return this; }
  order(column: string, options?: { ascending?: boolean }) { this.query.order = { column, ascending: options?.ascending }; return this; }
  limit(limit: number) { this.query.limit = limit; return this; }
  maybeSingle(): Promise<Result<DbRow>> { this.query.maybeSingle = true; return this.execute<DbRow>(); }
  insert(values: Record<string, unknown> | Array<Record<string, unknown>>) { this.query.action = "insert"; this.query.values = values; return this; }
  upsert(values: Record<string, unknown> | Array<Record<string, unknown>>, _options?: { onConflict?: string }) { this.query.action = "upsert"; this.query.values = values; return this; }
  update(values: Record<string, unknown>) { this.query.action = "update"; this.query.values = values; return this; }
  delete() { this.query.action = "delete"; return this; }

  then<TResult1 = Result<DbRow[]>, TResult2 = never>(
    onfulfilled?: ((value: Result<DbRow[]>) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return this.execute().then(onfulfilled, onrejected);
  }

  private addFilter(filter: { column: string; operator: "eq" | "neq"; value: unknown }) {
    const filters = (this.query.filters as typeof filter[] | undefined) ?? [];
    this.query.filters = [...filters, filter];
  }

  private async execute<T = DbRow[]>(): Promise<Result<T>> {
    try {
      const response = await request<{ data: T; error: ApiError | null }>(`data/${encodeURIComponent(this.table)}`, {
        method: "POST", body: JSON.stringify(this.query),
      });
      return resultOf(response.data, response.error);
    } catch (error) { return resultOf<T>(null, toApiError(error)); }
  }
}

class StorageBucket {
  constructor(private readonly bucket: string) {}
  async upload(path: string, file: File, options: { contentType?: string } = {}): Promise<Result<{ path: string }>> {
    const contentType = options.contentType || file.type || "application/octet-stream";
    try {
      const { uploadUrl, intentId, requiredHeaders } = await request<{ uploadUrl: string; intentId: string; requiredHeaders: Record<string, string> }>("storage/upload-url", {
        method: "POST", body: JSON.stringify({ bucket: this.bucket, path, size: file.size, contentType }),
      });
      const uploaded = await fetch(uploadUrl, { method: "PUT", headers: requiredHeaders, body: file });
      if (!uploaded.ok) throw new Error(`R2 menolak unggahan (${uploaded.status})`);
      await request("storage/complete-upload", {
        method: "POST", body: JSON.stringify({ intentId }),
      });
      return resultOf({ path });
    } catch (error) { return resultOf<{ path: string }>(null, toApiError(error)); }
  }
  async remove(paths: string[]): Promise<Result<unknown>> {
    try { return resultOf(await request(`storage/${encodeURIComponent(this.bucket)}`, { method: "DELETE", body: JSON.stringify({ paths }) })); }
    catch (error) { return resultOf(null, toApiError(error)); }
  }
  async createSignedUrl(path: string, _expiresIn = 300): Promise<Result<{ signedUrl: string }>> {
    try {
      const result = await request<{ signedUrl: string }>(`storage/${encodeURIComponent(this.bucket)}/signed-url`, {
        method: "POST", body: JSON.stringify({ path }),
      });
      return resultOf(result);
    } catch (error) { return resultOf<{ signedUrl: string }>(null, toApiError(error)); }
  }
}

class RealtimeChannel {
  private source: EventSource | null = null;
  on(_type: string, _filter: Record<string, unknown>, callback: () => void) { this.callback = callback; return this; }
  subscribe(callback?: (status: string) => void) {
    try {
      this.source = new EventSource("/api/backend/realtime/events");
      this.source.onopen = () => callback?.("SUBSCRIBED");
      this.source.onmessage = () => this.callback?.();
      this.source.onerror = () => callback?.("CHANNEL_ERROR");
    } catch { callback?.("CHANNEL_ERROR"); }
    return this;
  }
  close() { this.source?.close(); this.source = null; }
  private callback?: () => void;
}

export class ThreadlineClient {
  readonly auth = {
    signInWithPassword: async (input: { email: string; password: string; otp?: string }) => {
      try {
        const data = await request<{ user: AuthUser }>("auth/sign-in", { method: "POST", body: JSON.stringify(input) });
        notifyAuth("SIGNED_IN");
        return { data: { user: data.user, session: { user: data.user } }, error: null };
      } catch (error) { return { data: { user: null, session: null }, error: toApiError(error) }; }
    },
    signUp: async (input: { email: string; password: string; options?: { data?: Record<string, string> } }) => {
      try { return { data: await request("auth/sign-up", { method: "POST", body: JSON.stringify({ email: input.email, password: input.password, data: input.options?.data }) }), error: null }; }
      catch (error) { return { data: null, error: toApiError(error) }; }
    },
    resetPasswordForEmail: async (email: string, _options?: { redirectTo?: string }) => {
      try { return { data: await request("auth/reset-password", { method: "POST", body: JSON.stringify({ email }) }), error: null }; }
      catch (error) { return { data: null, error: toApiError(error) }; }
    },
    updateUser: async (input: { password: string }) => {
      try {
        const data = await request("auth/update-password", { method: "POST", body: JSON.stringify({ password: input.password }) });
        notifyAuth("USER_UPDATED");
        return { data: { user: null, ...data as object }, error: null };
      } catch (error) { return { data: null, error: toApiError(error) }; }
    },
    getUser: async () => {
      try { const data = await request<{ user: AuthUser | null }>("auth/session"); return { data: { user: data.user }, error: null }; }
      catch (error) { return { data: { user: null }, error: toApiError(error) }; }
    },
    getSession: async () => {
      try { const data = await request<{ user: unknown; session: unknown }>("auth/session"); return { data: { session: data.session ? { ...data.session as object, user: data.user, access_token: "http-only-cookie" } : null }, error: null }; }
      catch (error) { return { data: { session: null }, error: toApiError(error) }; }
    },
    exchangeCodeForSession: async (code: string) => {
      try {
        const data = await request<{ user: unknown; purpose: string }>("auth/exchange-code", { method: "POST", body: JSON.stringify({ code }) });
        notifyAuth("SIGNED_IN");
        return { data: { user: data.user, session: { user: data.user, access_token: "http-only-cookie" } }, error: null };
      } catch (error) { return { data: { user: null, session: null }, error: toApiError(error) }; }
    },
    onAuthStateChange: (callback: (event: string) => void) => {
      const handler = (event: Event) => callback((event as CustomEvent<string>).detail);
      if (typeof window !== "undefined") window.addEventListener("threadline:auth", handler);
      return { data: { subscription: { unsubscribe: () => window.removeEventListener("threadline:auth", handler) } } };
    },
    resend: async (input: { type: string; email: string }) => {
      try { return { data: await request("auth/resend-verification", { method: "POST", body: JSON.stringify({ email: input.email }) }), error: null }; }
      catch (error) { return { data: null, error: toApiError(error) }; }
    },
    beginMfaEnrollment: async (input: { email: string; password: string }) => request<{ secret: string; otpauthUrl: string }>("auth/mfa/enroll", { method: "POST", body: JSON.stringify(input) }),
    confirmMfaEnrollment: async (input: { email: string; password: string; code: string }) => {
      try {
        const data = await request<{ user: unknown }>("auth/mfa/confirm", { method: "POST", body: JSON.stringify(input) });
        notifyAuth("SIGNED_IN");
        return { data: { user: data.user }, error: null };
      } catch (error) { return { data: null, error: toApiError(error) }; }
    },
    signOut: async () => {
      try { await request("auth/sign-out", { method: "POST", body: "{}" }); notifyAuth("SIGNED_OUT"); return { error: null }; }
      catch (error) { return { error: toApiError(error) }; }
    },
  };

  from(table: string) { return new QueryBuilder(table); }
  rpc(name: string, args: Record<string, unknown> = {}): Promise<Result<unknown>> {
    return request<{ data: unknown; error: ApiError | null }>(`rpc/${encodeURIComponent(name)}`, { method: "POST", body: JSON.stringify({ args }) })
      .then((result) => resultOf(result.data, result.error))
      .catch((error) => resultOf(null, toApiError(error)));
  }
  storage = { from: (bucket: string) => new StorageBucket(bucket) };
  channel(_name: string) { return new RealtimeChannel(); }
  async removeChannel(channel: RealtimeChannel) { channel.close(); }
}

let client: ThreadlineClient | null = null;
export function createClient() {
  client ??= new ThreadlineClient();
  return client;
}

export async function exchangeCodeForSession(code: string): Promise<boolean> {
  try {
    await request("auth/exchange-code", { method: "POST", body: JSON.stringify({ code }) });
    notifyAuth("SIGNED_IN");
    return true;
  } catch { return false; }
}
