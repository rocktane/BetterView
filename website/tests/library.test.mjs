import { test } from "node:test";
import assert from "node:assert/strict";
import { Library } from "../src/scripts/model.mjs";

const photos = Array.from({ length: 6 }, (_, id) => ({
  id,
  burst: id < 3 ? 1 : 2,
  locked: id === 5,
}));
const selected = (model) => [...model.selected].sort((a, b) => a - b);
const photoIDs = (model) => model.photos.map((photo) => photo.id);

test("range selection expands and contracts from the anchor", () => {
  const model = new Library(photos);
  model.move(2, true);
  assert.deepEqual(selected(model), [0, 1, 2]);
  model.move(-1, true);
  assert.deepEqual(selected(model), [0, 1]);
});

test("disjoint selection survives range extension, contraction and reversal", () => {
  const model = new Library(photos);
  model.go(0, false, true);
  model.go(4, false, true);
  model.go(5, true);
  assert.deepEqual(selected(model), [0, 4, 5]);
  model.go(4, true);
  assert.deepEqual(selected(model), [0, 4]);
  model.go(2, true);
  assert.deepEqual(selected(model), [0, 2, 3, 4]);
  model.go(3, true);
  assert.deepEqual(selected(model), [0, 3, 4]);
});

test("plain navigation and deselection end the current range", () => {
  const model = new Library(photos);
  model.go(0, false, true);
  model.go(4, false, true);
  model.go(2);
  model.move(1, true);
  assert.deepEqual(selected(model), [0, 2, 3, 4]);
  model.toggle();
  model.move(-1, true);
  assert.deepEqual(selected(model), [0, 2, 3, 4]);
});

test("compare requires at least two explicitly selected photos", () => {
  const model = new Library(photos);
  model.compare();
  assert.deepEqual(model.comparison, []);
  model.selected.add(0);
  model.compare();
  assert.deepEqual(model.comparison, []);
  model.selected = new Set([1, 4]);
  model.compare();
  assert.deepEqual(model.comparison, [1, 4]);
});

test("group deletion preserves protected photos and undo restores the group", () => {
  const model = new Library(photos);
  assert.equal(model.remove([0, 1, 5]), 2);
  assert.deepEqual(photoIDs(model), [2, 3, 4, 5]);
  assert.ok(Array.isArray(model.history[0]));
  assert.deepEqual(
    [...model.history[0]],
    [
      { photo: photos[0], index: 0 },
      { photo: photos[1], index: 1 },
    ],
  );
  model.restore();
  assert.deepEqual(model.photos, photos);
  assert.equal(model.current, 0);
});

test("deleting every unprotected photo leaves a navigable protected photo", () => {
  const model = new Library(photos);
  model.remove(photos.map((photo) => photo.id));
  assert.equal(model.current, 5);
  model.move(10);
  assert.equal(model.current, 5);
  assert.equal(model.remove([5]), 0);
});

test("empty library can recover through undo", () => {
  const model = new Library(photos.slice(0, 2));
  model.remove([0, 1]);
  model.move(1);
  assert.equal(model.current, undefined);
  model.restore();
  assert.equal(model.photos.length, 2);
});

test("history can restore older groups without disturbing photo order", () => {
  const model = new Library(photos);
  model.remove([0]);
  model.remove([1]);
  model.restore(0);
  model.restore(0);
  assert.deepEqual(photoIDs(model), [0, 1, 2, 3, 4, 5]);
});

test("undo restores comparison views in their original order", () => {
  const model = new Library(photos);
  model.selected = new Set([0, 1, 2]);
  model.compare();
  model.remove([0]);
  assert.deepEqual(model.comparison, [1, 2]);
  model.restore();
  assert.deepEqual(model.comparison, [0, 1, 2]);
});

test("comparison group undo preserves protected members", () => {
  const model = new Library(photos);
  model.go(3);
  model.selected = new Set([3, 4, 5]);
  model.compare();
  assert.equal(model.remove([3, 4, 5]), 2);
  assert.deepEqual(model.comparison, []);
  assert.deepEqual(photoIDs(model), [0, 1, 2, 5]);
  model.restore();
  assert.deepEqual(model.comparison, [3, 4, 5]);
  assert.deepEqual(model.photos, photos);
});

test("out-of-order undo restores comparison without reviving other deletions", () => {
  const model = new Library(photos);
  model.selected = new Set([0, 1, 2]);
  model.compare();
  model.remove([0]);
  model.remove([1]);
  assert.deepEqual(model.comparison, []);
  model.restore(0);
  assert.deepEqual(model.comparison, [0, 2]);
  assert.deepEqual(photoIDs(model), [0, 2, 3, 4, 5]);
  model.restore(0);
  assert.deepEqual(model.comparison, [0, 1, 2]);
  assert.deepEqual(model.photos, photos);
});

test("comparison returns from one survivor and reset clears session state", () => {
  const model = new Library(photos);
  model.selected = new Set([0, 1, 2]);
  model.compare();
  model.remove([0, 1]);
  assert.deepEqual(model.comparison, []);
  model.restore();
  assert.deepEqual(model.comparison, [0, 1, 2]);
  model.reset();
  assert.deepEqual(model.photos, photos);
  assert.equal(model.history.length, 0);
  assert.deepEqual(model.comparison, []);
  model.remove([0]);
  model.restore();
  assert.deepEqual(model.comparison, []);
});
