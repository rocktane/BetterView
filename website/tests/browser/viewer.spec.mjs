import { test, expect } from "@playwright/test";
const thumbs = (page) => page.locator(".thumb-photo");
const slots = (page) => page.locator(".slot");
const action = (page, name) => page.locator(`[data-action="${name}"]`).first();
async function open(page, route = "essayer/") {
  await page.goto(route);
  await expect(thumbs(page)).toHaveCount(8);
  await expect(slots(page).first().locator("img")).toBeVisible();
}
test("disjoint selection, changing range and independent keyboard checkboxes", async ({
  page,
}) => {
  await open(page);
  await thumbs(page)
    .nth(0)
    .click({ position: { x: 4, y: 48 }, modifiers: ["ControlOrMeta"] });
  await thumbs(page)
    .nth(4)
    .click({ position: { x: 4, y: 48 }, modifiers: ["ControlOrMeta"] });
  await thumbs(page)
    .nth(5)
    .click({ position: { x: 4, y: 48 }, modifiers: ["Shift"] });
  await expect(page.locator(".thumb.selected")).toHaveCount(3);
  await thumbs(page)
    .nth(4)
    .click({ position: { x: 4, y: 48 }, modifiers: ["Shift"] });
  await expect(page.locator(".thumb.selected")).toHaveCount(2);
  const check = page.locator(".selection-toggle").nth(0);
  await check.focus();
  await page.keyboard.press("Space");
  await expect(check).toHaveAttribute("aria-pressed", "false");
  await expect(thumbs(page).nth(4)).toHaveAttribute("aria-current", "true");
  await expect(page.locator("[data-announcement]")).toContainText("5 sur 8");
});
test("comparison trash and undo restore the work context; explicit exit clears it", async ({
  page,
}) => {
  await open(page, "comparer/");
  await expect(slots(page)).toHaveCount(3);
  await slots(page).first().hover();
  await slots(page)
    .first()
    .getByRole("button", { name: "Corbeille", exact: true })
    .click();
  await expect(slots(page)).toHaveCount(2);
  await action(page, "undo").click();
  await expect(slots(page)).toHaveCount(3);
  await action(page, "single").click();
  await action(page, "delete").click();
  await action(page, "undo").click();
  await expect(slots(page)).toHaveCount(1);
  await action(page, "history").click();
  await expect(
    page.getByRole("dialog", { name: "Historique des suppressions" }),
  ).toBeVisible();
});
test("Space activates its button and A toggles AF", async ({ page }) => {
  await open(page);
  await page.locator(".selection-toggle").nth(0).click();
  await page.locator(".selection-toggle").nth(1).click();
  await action(page, "compare").focus();
  await page.keyboard.press("Space");
  await expect(slots(page)).toHaveCount(2);
  await page.locator("[data-viewer]").focus();
  await page.keyboard.press("a");
  await expect(action(page, "focus")).toHaveAttribute("aria-pressed", "true");
  await page.keyboard.press("a");
  await expect(action(page, "focus")).toHaveAttribute("aria-pressed", "false");
  await expect(page.locator(".stage")).not.toHaveClass(/zoomed/);
});
test("same photo heights and natural thumbnail ratios survive resize", async ({
  page,
}) => {
  await open(page);
  const first = await slots(page).first().boundingBox();
  await thumbs(page)
    .nth(4)
    .click({ position: { x: 4, y: 48 } });
  const portrait = await slots(page).first().boundingBox();
  expect(Math.abs(first.height - portrait.height)).toBeLessThan(1);
  for (const width of [1440, 390, 320]) {
    await page.setViewportSize({ width, height: 800 });
    const ratios = await page.locator(".thumb-photo img").evaluateAll((imgs) =>
      imgs.map((img) => ({
        actual:
          img.getBoundingClientRect().width /
          img.getBoundingClientRect().height,
        natural:
          Number(img.getAttribute("width")) /
          Number(img.getAttribute("height")),
      })),
    );
    for (const r of ratios)
      expect(Math.abs(r.actual - r.natural)).toBeLessThan(0.02);
  }
});
test("touch comparison reserves real photo and action areas at 320px", async ({
  browser,
}) => {
  const context = await browser.newContext({
    viewport: { width: 320, height: 700 },
    hasTouch: true,
    isMobile: true,
  });
  const page = await context.newPage();
  await page.goto(test.info().project.use.baseURL + "comparer/");
  await expect(slots(page)).toHaveCount(3);
  expect(await page.evaluate(() => matchMedia("(hover:none)").matches)).toBe(
    true,
  );
  for (const slot of await slots(page).all()) {
    const box = await slot.boundingBox();
    const image = await slot.locator("img").boundingBox();
    const buttons = slot.locator(".slot-actions button");
    expect(image.height).toBeGreaterThan(20);
    expect(image.y + image.height).toBeLessThanOrEqual(box.y + box.height - 87);
    for (const button of await buttons.all())
      expect((await button.boundingBox()).height).toBeGreaterThanOrEqual(44);
    await expect(slot.locator(".info")).toBeHidden();
  }
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await context.close();
});
test("responsive previews, HD on zoom only, persistent nodes and bounded wheel/gesture pan", async ({
  page,
}) => {
  const hd = [];
  page.on("request", (request) => {
    if (/-full\.webp/.test(request.url())) hd.push(request.url());
  });
  await open(page);
  expect(hd).toHaveLength(0);
  const image = slots(page).first().locator("img");
  await expect(image).toHaveAttribute("srcset", /320w/);
  const original = await image.elementHandle();
  await slots(page).first().dispatchEvent("wheel", {
    ctrlKey: true,
    deltaY: -70,
    clientX: 250,
    clientY: 250,
  });
  await expect(page.locator(".stage")).toHaveClass(/zoomed/);
  await expect.poll(() => hd.length).toBeGreaterThan(0);
  await page
    .locator(".stage")
    .dispatchEvent("wheel", { deltaX: 99999, deltaY: -99999 });
  expect(
    await original.evaluate(
      (node) => node === document.querySelector(".slot img"),
    ),
  ).toBe(true);
  const bounds = await slots(page)
    .first()
    .evaluate((slot) => {
      const i = slot.querySelector("img").getBoundingClientRect(),
        s = slot.getBoundingClientRect();
      return (
        i.left <= s.left + 1 &&
        i.right >= s.right - 1 &&
        i.top <= s.top + 1 &&
        i.bottom >= s.bottom - 1
      );
    });
  expect(bounds).toBe(true);
  await page.locator(".stage").evaluate((stage) => {
    for (const [type, scale] of [
      ["gesturestart", 1],
      ["gesturechange", 1.2],
      ["gestureend", 1.2],
    ]) {
      const e = new Event(type, { cancelable: true });
      Object.assign(e, { scale, clientX: 250, clientY: 250 });
      stage.dispatchEvent(e);
    }
  });
  expect(await original.evaluate((node) => node.isConnected)).toBe(true);
});
test("failed HD retains usable preview", async ({ page }) => {
  await page.route("**/*-full.webp", (route) => route.abort());
  await open(page);
  await action(page, "zoom").click();
  await expect
    .poll(() =>
      slots(page)
        .first()
        .locator("img")
        .evaluate((img) => img.complete && img.naturalWidth > 0),
    )
    .toBe(true);
  await expect(slots(page).first().locator("img")).not.toHaveAttribute(
    "src",
    /-full.webp/,
  );
});
test("fullscreen uses available height", async ({ page }) => {
  await open(page);
  await page.setViewportSize({ width: 1440, height: 1000 });
  const before = await page.locator(".stage").boundingBox();
  await action(page, "fullscreen").click();
  await expect
    .poll(() => page.evaluate(() => !!document.fullscreenElement))
    .toBe(true);
  expect(
    (await page.locator(".stage").boundingBox()).height,
  ).toBeGreaterThanOrEqual(before.height);
  await page.evaluate(() => document.exitFullscreen());
});
test("base links, local image loading and no-JS fallback", async ({
  browser,
  page,
}) => {
  await open(page);
  const base = new URL(test.info().project.use.baseURL).pathname;
  expect(await page.locator("[data-viewer]").getAttribute("data-base")).toBe(
    base,
  );
  expect(await thumbs(page).first().locator("img").getAttribute("src")).toMatch(
    new RegExp("^" + base),
  );
  const context = await browser.newContext({ javaScriptEnabled: false });
  const fallback = await context.newPage();
  await fallback.goto(
    new URL("essayer/", test.info().project.use.baseURL).href,
  );
  await expect(fallback.locator(".fallback-photo")).toBeVisible();
  await expect(
    fallback.getByText("Activez JavaScript", { exact: false }),
  ).toBeVisible();
  expect(
    await fallback
      .locator(".fallback-photo")
      .evaluate((img) => img.complete && img.naturalWidth > 0),
  ).toBe(true);
  await context.close();
});
test("preview errors keep a thumbnail and announce the failure", async ({
  page,
}) => {
  await page.route(
    /\/images\/coast-(preview|320|640|960|1400)\.webp$/,
    (route) => route.abort(),
  );
  await open(page);
  await expect
    .poll(() =>
      slots(page)
        .first()
        .locator("img")
        .evaluate(
          (img) =>
            img.currentSrc.endsWith("-thumb.webp") &&
            img.complete &&
            img.naturalWidth > 0,
        ),
    )
    .toBe(true);
  await expect(page.locator("[data-toast]")).toContainText(
    "Aperçu indisponible",
  );
});
test("comparison zoom requests only its visible HD files and keeps strip nodes", async ({
  page,
}) => {
  const hd = new Set();
  page.on("request", (request) => {
    if (/-full\.webp/.test(request.url())) hd.add(request.url());
  });
  await open(page, "comparer/");
  expect(hd.size).toBe(0);
  const thumb = await thumbs(page).first().elementHandle();
  const image = await slots(page).first().locator("img").elementHandle();
  await expect(slots(page).first().locator("img")).toHaveAttribute(
    "loading",
    "lazy",
  );
  await action(page, "zoom").click();
  await expect.poll(() => hd.size).toBe(3);
  await page.locator(".stage").dispatchEvent("wheel", {
    ctrlKey: true,
    deltaY: -15,
    clientX: 150,
    clientY: 200,
  });
  expect(
    await thumb.evaluate(
      (node) => node === document.querySelector(".thumb-photo"),
    ),
  ).toBe(true);
  expect(
    await image.evaluate(
      (node) => node === document.querySelector(".slot img"),
    ),
  ).toBe(true);
});

test("successive deletion keeps keyboard focus, current photo and counters", async ({
  page,
}) => {
  await open(page);
  await thumbs(page).first().click();
  for (const [key, id, count] of [
    ["Backspace", 0, 7],
    ["x", 2, 6],
  ]) {
    await page.keyboard.press(key);
    await expect(thumbs(page)).toHaveCount(count);
    await expect(slots(page)).toHaveAttribute("data-id", String(id));
    await expect(page.locator(".thumb.current")).toHaveAttribute(
      "data-id",
      String(id),
    );
    await expect(page.locator("[data-announcement]")).toContainText(
      `1 sur ${count}`,
    );
  }
  await action(page, "delete").click();
  await page.keyboard.press("Backspace");
  await expect(thumbs(page)).toHaveCount(4);
  await expect(slots(page)).toHaveAttribute("data-id", "4");
  // A surviving thumbnail must navigate using its new index, preserving its node.
  await page
    .locator('.thumb[data-id="6"] .thumb-photo')
    .click({ position: { x: 4, y: 48 } });
  await expect(slots(page)).toHaveAttribute("data-id", "6");
  await expect(page.locator("[data-announcement]")).toContainText("3 sur 4");
});

test("comparison deletion clears removed hover and returns focus from removed actions", async ({
  page,
}) => {
  await open(page, "comparer/");
  await slots(page).first().dispatchEvent("pointerenter");
  await page.locator("[data-viewer]").focus();
  await page.keyboard.press("Backspace");
  await expect(thumbs(page)).toHaveCount(7);
  // Seeded comparison members are explicitly selected, so delete acts on the survivors.
  await page.keyboard.press("x");
  await expect(thumbs(page)).toHaveCount(5);
  await expect(slots(page)).toHaveAttribute("data-id", "3");
  await action(page, "undo").click();
  await slots(page)
    .first()
    .getByRole("button", { name: "Corbeille", exact: true })
    .click();
  await page.keyboard.press("Backspace");
  await expect(thumbs(page)).toHaveCount(5);
});

test("group deletion can continue on current photo and preserves protection and undo", async ({
  page,
}) => {
  await open(page);
  for (const id of [0, 1, 7])
    await page.locator(`.thumb[data-id="${id}"] .selection-toggle`).click();
  await page.keyboard.press("Backspace");
  await expect(thumbs(page)).toHaveCount(6);
  await expect(slots(page)).toHaveAttribute("data-id", "2");
  await page.keyboard.press("x");
  // The protected selection remains selected; deselect it before deleting current.
  await expect(thumbs(page)).toHaveCount(6);
  await page.locator('.thumb[data-id="7"] .selection-toggle').click();
  await page.keyboard.press("x");
  await expect(thumbs(page)).toHaveCount(5);
  await expect(slots(page)).toHaveAttribute("data-id", "3");
  await expect(page.locator("[data-announcement]")).toContainText("1 sur 5");
  await action(page, "undo").click();
  await expect(slots(page)).toHaveAttribute("data-id", "2");
  await expect(thumbs(page)).toHaveCount(6);
});

test("deleting a selected group continues without clicking the strip", async ({
  page,
}) => {
  await open(page);
  await page.locator('.thumb[data-id="0"] .selection-toggle').click();
  await page.locator('.thumb[data-id="1"] .selection-toggle').click();
  await page.keyboard.press("Backspace");
  await expect(thumbs(page)).toHaveCount(6);
  await expect(page.locator(".thumb.selected")).toHaveCount(0);
  await expect(slots(page)).toHaveAttribute("data-id", "2");
  await expect(page.locator("[data-announcement]")).toContainText("1 sur 6");
  await page.keyboard.press("x");
  await expect(thumbs(page)).toHaveCount(5);
  await expect(slots(page)).toHaveAttribute("data-id", "3");
  await expect(page.locator("[data-announcement]")).toContainText("1 sur 5");
});

test("visible viewer handles keys before click without moving focus, comparison requires selection", async ({
  page,
}) => {
  await open(page);
  await page.locator("[data-film]").scrollIntoViewIfNeeded();
  await expect
    .poll(() => page.evaluate(() => document.activeElement.tagName))
    .toBe("BODY");
  await page.keyboard.press("ArrowRight");
  await expect(slots(page)).toHaveAttribute("data-id", "0");
  await expect(action(page, "compare")).toBeDisabled();
  await expect(action(page, "comparison")).toBeDisabled();
  await page.keyboard.press("c");
  await expect(slots(page)).toHaveCount(1);
  await expect(page.locator("[data-toast]")).toContainText("au moins deux");
  await page.keyboard.press("s");
  await page.keyboard.press("c");
  await expect(slots(page)).toHaveCount(1);
  await page.keyboard.press("Shift+ArrowRight");
  await expect(action(page, "compare")).toBeEnabled();
  await page.keyboard.press("c");
  await expect(slots(page)).toHaveCount(2);
  expect(await page.evaluate(() => document.activeElement.tagName)).toBe(
    "BODY",
  );
});

test("pointer anchors keyboard zoom just like click and wheel; AF marker follows pan", async ({
  page,
}) => {
  await open(page);
  await slots(page).first().scrollIntoViewIfNeeded();
  const slot = slots(page).first();
  const box = await slot.boundingBox();
  const x = Math.round(box.x + box.width * 0.7),
    y = Math.round(box.y + box.height * 0.65);
  await page.mouse.move(x, y);
  const transform = () =>
    slot.locator("img").evaluate((img) => img.style.transform);
  await page.keyboard.press("z");
  const keyboard = await transform();
  expect(keyboard).not.toContain("+ 0px");
  await page.keyboard.press("0");
  await page.mouse.click(x, y);
  expect(await transform()).toBe(keyboard);
  await page.keyboard.press("0");
  await slot.dispatchEvent("wheel", {
    ctrlKey: true,
    deltaY: -Math.log(2) * 100,
    clientX: x,
    clientY: y,
  });
  expect(await transform()).toBe(keyboard);
  await page.keyboard.press("+");
  await expect(slot.locator(".zoom-label")).toHaveText("250 %");
  await page.keyboard.press("-");
  await expect(slot.locator(".zoom-label")).toHaveText("200 %");
  await page.keyboard.press("a");
  await expect(slot.locator(".marker")).toBeVisible();
  const before = await slot.locator(".marker").getAttribute("style");
  await slot.dispatchEvent("wheel", { deltaX: 25, deltaY: 20 });
  await expect(slot.locator(".marker")).toBeVisible();
  expect(await slot.locator(".marker").getAttribute("style")).not.toBe(before);
  await page.keyboard.press("a");
  await expect(slot.locator(".marker")).toBeHidden();
});

test("document shortcuts leave controls, modal focus and offscreen page alone", async ({
  page,
}) => {
  await open(page);
  await page.locator("[data-film]").scrollIntoViewIfNeeded();
  const initial = await slots(page).getAttribute("data-id");
  await page.evaluate(() => {
    const input = document.createElement("input");
    input.id = "outside-input";
    document.querySelector("[data-viewer]").prepend(input);
    input.focus({ preventScroll: true });
  });
  await page.keyboard.press("s");
  await expect(page.locator("#outside-input")).toHaveValue("s");
  await page.keyboard.press("ArrowRight");
  await expect(slots(page)).toHaveAttribute("data-id", initial);
  await action(page, "history").click();
  await expect(page.locator("dialog[open]")).toBeVisible();
  expect(
    await page.evaluate(() => !!document.activeElement.closest("dialog")),
  ).toBe(true);
  await page.keyboard.press("ArrowRight");
  await expect(slots(page)).toHaveAttribute("data-id", initial);
  await page.keyboard.press("Escape");
  await page.evaluate(() => {
    document.activeElement.blur();
    const spacer = document.createElement("div");
    spacer.style.height = "2000px";
    document.body.append(spacer);
    window.scrollTo(0, document.body.scrollHeight);
  });
  await expect(page.locator("[data-viewer]")).not.toBeInViewport();
  await page.waitForTimeout(100);
  await page.keyboard.press("ArrowRight");
  await expect(slots(page)).toHaveAttribute("data-id", initial);
});

test("home trial navigation activates shortcuts while preserving link focus", async ({
  page,
}) => {
  await page.goto("");
  const link = page
    .locator(".nav")
    .getByRole("link", { name: "Essayer", exact: true });
  await link.click();
  await expect(page.locator("[data-film]")).toBeInViewport();
  // Fragment navigation may reset focus to body; exercise a link that retains it too.
  await link.evaluate((node) => node.focus({ preventScroll: true }));
  await expect(link).toBeFocused();
  await page.keyboard.press("ArrowRight");
  await expect(slots(page)).toHaveAttribute("data-id", "0");
  await expect(link).toBeFocused();
});

test("keycaps animate on initial document keydown without clicking the viewer", async ({
  page,
}) => {
  await open(page);
  await page.locator("[data-film]").scrollIntoViewIfNeeded();
  await expect
    .poll(() => page.evaluate(() => document.activeElement === document.body))
    .toBe(true);
  const key = action(page, "zoom").locator("kbd");
  await page.keyboard.down("z");
  await expect(key).toHaveClass(/is-held/);
  await page.keyboard.up("z");
  await expect(key).not.toHaveClass(/is-held/);
});
