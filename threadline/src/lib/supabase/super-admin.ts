import "server-only";

import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { createClient } from "./server";
import { hasSameOrigin } from "./origin";
import type { Database } from "@/lib/database.types";

export { hasSameOrigin };

export async function requireSuperAdmin() {
  const supabase = await createClient();
  const { data: userResult } = await supabase.auth.getUser();
  const user = userResult.user;
  if (!user) return null;

  const { data: profile } = await supabase
    .from("profiles")
    .select("id,role,is_active,name")
    .eq("id", user.id)
    .maybeSingle();
  if (!profile || profile.role !== "super_admin" || !profile.is_active) return null;

  return { supabase, user, profile };
}

export async function requireRegistrationReviewer() {
  const supabase = await createClient();
  const { data: userResult } = await supabase.auth.getUser();
  const user = userResult.user;
  if (!user) return null;

  const { data: profile } = await supabase
    .from("profiles")
    .select("id,role,is_active,name")
    .eq("id", user.id)
    .maybeSingle();
  if (!profile || !profile.is_active || !["admin", "super_admin"].includes(profile.role)) return null;

  return { supabase, user, profile };
}

export async function requireSuperAdminMfa() {
  const access = await requireRegistrationReviewer();
  if (!access || access.profile.role !== "super_admin") return null;
  const { data: isSuperAdmin, error } = await access.supabase.rpc("is_super_admin");
  if (error || !isSuperAdmin) return null;
  return access;
}

export function createServiceRoleClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  return createSupabaseClient<Database>(url, key, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
}

export function getAuthRedirectUrl(path: string, requestUrl: string) {
  const baseUrl = process.env.NEXT_PUBLIC_SITE_URL ?? new URL(requestUrl).origin;
  return new URL(path, baseUrl).toString();
}
