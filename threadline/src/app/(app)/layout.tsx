import { StoreProvider } from "@/lib/store-context";
import { AppFrame } from "@/components/app-frame";

// Seluruh area aplikasi: auth + realtime, render dinamis per request.
export const dynamic = "force-dynamic";

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <StoreProvider>
      <AppFrame>{children}</AppFrame>
    </StoreProvider>
  );
}
