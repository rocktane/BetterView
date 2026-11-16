const { default: sharp } = await import(process.env.SHARP_MODULE || "sharp");
import { readFile, writeFile } from "node:fs/promises";
const dataURL = new URL("../src/scripts/photos.json", import.meta.url);
const photos = JSON.parse(await readFile(dataURL, "utf8"));
for (const photo of photos) {
  photo.responsive = [];
  for (const width of [320, 640, 960, 1400]) {
    const src = photo.preview.replace("-preview.webp", `-${width}.webp`);
    await sharp(new URL(`../public${photo.preview}`, import.meta.url).pathname)
      .resize({ width, withoutEnlargement: true })
      .webp({ quality: 78 })
      .toFile(new URL(`../public${src}`, import.meta.url).pathname);
    photo.responsive.push({ src, width });
  }
}
await writeFile(dataURL, `${JSON.stringify(photos, null, 2)}\n`);
