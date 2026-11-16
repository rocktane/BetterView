import { defineConfig } from "astro/config";

export default defineConfig({
  output: "static",
  site: "https://betterview.photos",
  base: process.env.ASTRO_BASE_PATH || "/",
});
