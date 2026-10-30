import { defineConfig } from "vite";
import preact from "@preact/preset-vite";
import { resolve } from "node:path";

// Four pages, one per window: the dashboard, the pill, the toasts and the call tracker.
export default defineConfig({
  plugins: [preact()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: {
    target: "es2022",
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        pill: resolve(__dirname, "pill.html"),
        toast: resolve(__dirname, "toast.html"),
        tracker: resolve(__dirname, "tracker.html"),
      },
    },
  },
  test: { environment: "node" },
} as any);
