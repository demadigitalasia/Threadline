import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Threadline — Platform Kolaborasi Freelancer",
  description: "Platform kolaborasi freelancer dan tim untuk mengelola proyek, tugas, revisi, persetujuan, dan fee.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="id" className="h-full antialiased">
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
