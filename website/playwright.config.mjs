import { defineConfig } from "@playwright/test";
const base = process.env.ASTRO_BASE_PATH || "/";
export default defineConfig({
  testDir: "./tests/browser",
  use: { baseURL: `http://127.0.0.1:4397${base}` },
  webServer: {
    command: "pnpm preview --host 127.0.0.1 --port 4397",
    url: `http://127.0.0.1:4397${base}`,
    reuseExistingServer: false,
  },
});
