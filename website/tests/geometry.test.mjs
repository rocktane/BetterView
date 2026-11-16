import { test } from "node:test";
import assert from "node:assert/strict";
import {
  centerForZoom,
  photoGeometry,
  centeredGeometry,
  centerFromOffset,
} from "../src/scripts/geometry.mjs";
test("landscape zoom clamps each axis independently", () => {
  const g = photoGeometry(1000, 500, 2, 2, { x: 99999, y: -99999 });
  assert.equal(g.x, 500);
  assert.equal(g.y, -250);
});
test("portrait remains uncropped at fit and cannot pan beyond its edges", () => {
  const g = photoGeometry(1000, 500, 2 / 3, 1, { x: 999, y: 999 });
  assert.equal(g.height, 500);
  assert.equal(g.x, 0);
  assert.equal(g.y, 0);
});
test("zoomed portrait can pan vertically while narrower than its slot", () => {
  const g = photoGeometry(1000, 500, 2 / 3, 2, { x: 999, y: 999 });
  assert.equal(g.x, 0);
  assert.equal(g.y, 250);
});
test("AF near a corner cannot expose space beyond the image", () => {
  const g = photoGeometry(1000, 500, 2, 2, { x: 0, y: 0 }, { x: 0, y: 1 });
  assert.equal(g.x, 500);
  assert.equal(g.y, -250);
});

test("normalized center addresses the same relative point across mixed ratios", () => {
  const center = { x: 0.6, y: 0.55 };
  for (const ratio of [1.5, 2 / 3]) {
    const g = centeredGeometry(300 * ratio, 300, ratio, 3, center);
    assert.ok(Math.abs(0.5 - g.x / g.width - center.x) < 1e-10);
    assert.ok(Math.abs(0.5 - g.y / g.height - center.y) < 1e-10);
  }
});

test("offset conversion preserves a zoom anchor and clamps image edges", () => {
  const g = centeredGeometry(600, 400, 1.5, 2);
  const center = centerFromOffset(g, -100, 70);
  const moved = centeredGeometry(600, 400, 1.5, 2, center);
  assert.ok(Math.abs(moved.x + 100) < 1e-10);
  assert.ok(Math.abs(moved.y - 70) < 1e-10);
  for (const ratio of [0.5625, 2 / 3, 1.5]) {
    const edge = centeredGeometry(300 * ratio, 300, ratio, 4, {
      x: -100,
      y: 100,
    });
    assert.ok(edge.x <= (edge.width - 300 * ratio) / 2 + 1e-10);
    assert.ok(edge.y >= -(edge.height - 300) / 2 - 1e-10);
  }
});

test("zoom preserves the normalized point under an off-center pointer", () => {
  for (const ratio of [1.5, 2 / 3]) {
    const width = 400 * ratio,
      height = 400;
    const g = centeredGeometry(width, height, ratio, 2, { x: 0.55, y: 0.6 });
    const x = width * 0.15,
      y = height * 0.1;
    const anchor = {
      x: 0.5 + (x - g.x) / g.width,
      y: 0.5 + (y - g.y) / g.height,
    };
    const center = centerForZoom(g, 1.25, x, y);
    const next = centeredGeometry(width, height, ratio, 2.5, center);
    assert.ok(Math.abs(0.5 + (x - next.x) / next.width - anchor.x) < 1e-10);
    assert.ok(Math.abs(0.5 + (y - next.y) / next.height - anchor.y) < 1e-10);
    const fit = centeredGeometry(
      width,
      height,
      ratio,
      1,
      centerForZoom(next, 1 / 2.5, x, y),
    );
    assert.equal(Math.abs(fit.x), 0);
    assert.equal(Math.abs(fit.y), 0);
  }
});
