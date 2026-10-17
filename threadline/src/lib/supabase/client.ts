import { createBrowserClient } from "@supabase/ssr";

export function createClient() {
  // Fallback agar prerender/build tidak crash saat env belum diisi.
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "http://127.0.0.1:54321";
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "placeholder-key-isi-env-local";
  return createBrowserClient(url, key);
}
