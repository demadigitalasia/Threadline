import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  /* Data privat per-pengguna: tanpa Cache Components lintas user (kontrak teknis). */
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
