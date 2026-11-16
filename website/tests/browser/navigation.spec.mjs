import { test, expect } from "@playwright/test";

test("home trial link works and handwritten choice stays decorative", async ({
  page,
}) => {
  await page.goto("");
  const base = new URL(test.info().project.use.baseURL).pathname;
  await expect(
    page.locator(".nav a").filter({ hasText: "Comparer" }),
  ).toHaveCount(0);
  const trialLink = page
    .locator(".nav")
    .getByRole("link", { name: "Essayer", exact: true });
  await expect(trialLink).toHaveAttribute("href", `${base}#essayer`);
  await trialLink.click();
  expect(new URL(page.url()).hash).toBe("#essayer");
  await expect(page.locator("#essayer")).toBeInViewport();

  const choices = page.locator(".handwritten-choice");
  await expect(choices).toHaveCount(1);
  await expect(
    page.getByRole("link", { name: /^Essayer directement/ }),
  ).toHaveCount(0);
  expect(
    await choices.evaluateAll((nodes) =>
      nodes.every(
        (node) =>
          node.tagName !== "A" &&
          !node.hasAttribute("href") &&
          !node.hasAttribute("tabindex") &&
          !node.querySelector("a, [href], [tabindex]") &&
          getComputedStyle(node).cursor !== "pointer",
      ),
    ),
  ).toBe(true);
  await expect(choices.locator("marker[orient='auto']")).toHaveCount(1);
  await expect(choices.locator("path[marker-end]")).toHaveCount(1);

  await expect(page.getByText("Pellicule", { exact: true })).toHaveCount(0);
});

test("thumbnail ratios and compact padding survive resizing without minimum widths", async ({
  page,
}) => {
  await page.goto("");
  await expect(page.locator(".thumb")).toHaveCount(8);
  for (const width of [1440, 390, 320]) {
    await page.setViewportSize({ width, height: 800 });
    const dimensions = await page.locator(".thumb").evaluateAll((thumbs) =>
      thumbs.map((thumb) => {
        const photo = thumb.querySelector(".thumb-photo"),
          image = photo.querySelector("img");
        const outer = thumb.getBoundingClientRect(),
          inner = image.getBoundingClientRect();
        return {
          padding: outer.width - inner.width,
          height: inner.height,
          ratio: inner.width / inner.height,
          expected:
            Number(image.getAttribute("width")) /
            Number(image.getAttribute("height")),
          min: getComputedStyle(thumb).minWidth,
          photoMin: getComputedStyle(photo).minWidth,
        };
      }),
    );
    for (const dimension of dimensions) {
      expect(dimension.min).toBe("0px");
      expect(dimension.photoMin).toBe("0px");
      expect(Math.abs(dimension.ratio - dimension.expected)).toBeLessThan(0.02);
      expect(dimension.padding).toBeCloseTo(8, 0);
      expect(dimension.height).toBe(width <= 650 ? 45 : 54);
    }
    const check = page.locator(".selection-toggle").first();
    expect((await check.boundingBox()).width).toBeGreaterThanOrEqual(32);
    expect(
      await check.evaluate((node) =>
        parseFloat(getComputedStyle(node, "::before").width),
      ),
    ).toBeLessThanOrEqual(14);
  }
});
