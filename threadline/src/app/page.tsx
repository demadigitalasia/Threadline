import { redirect } from "next/navigation";
import { getBackendUser } from "@/lib/backend/server";

export const dynamic = "force-dynamic";

export default async function RootPage() {
  const user = await getBackendUser();
  redirect(user ? "/dashboard" : "/login");
}
