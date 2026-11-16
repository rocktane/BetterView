export class Library {
  constructor(photos) {
    this.original = photos;
    this.reset();
  }

  reset() {
    this.photos = [...this.original];
    this.current = this.photos[0]?.id;
    this.selected = new Set();
    this.anchor = this.current;
    this.rangeBase = null;
    this.history = [];
    this.comparison = [];
    this.comparisonOrder = null;
  }

  get index() {
    return this.photos.findIndex((photo) => photo.id === this.current);
  }

  move(offset, extend = false) {
    this.go(
      Math.max(0, Math.min(this.photos.length - 1, this.index + offset)),
      extend,
    );
  }

  go(index, extend = false, toggle = false) {
    const photo = this.photos[index];
    if (!photo) return;
    if (extend) {
      let start = this.photos.findIndex((item) => item.id === this.anchor);
      if (this.rangeBase === null || start < 0) {
        start = this.index;
        if (start < 0) start = index;
        this.anchor = this.photos[start].id;
        this.rangeBase = new Set(this.selected);
      }
      const range = this.photos.slice(
        Math.min(start, index),
        Math.max(start, index) + 1,
      );
      this.selected = new Set([
        ...this.rangeBase,
        ...range.map((item) => item.id),
      ]);
    } else if (toggle) {
      if (this.selected.has(photo.id)) {
        this.selected.delete(photo.id);
        this.rangeBase = null;
      } else {
        this.anchor = photo.id;
        this.rangeBase = new Set(this.selected);
        this.selected.add(photo.id);
      }
    } else {
      this.anchor = photo.id;
      this.rangeBase = null;
    }
    this.current = photo.id;
  }

  toggle() {
    this.go(this.index, false, true);
  }

  compare() {
    const group = this.photos.filter((photo) => this.selected.has(photo.id));
    if (group.length < 2) return false;
    this.comparison = group.map((photo) => photo.id);
    this.comparisonOrder = [...this.comparison];
    return true;
  }

  remove(ids) {
    const removed = this.photos.flatMap((photo, index) =>
      ids.includes(photo.id) && !photo.locked ? [{ photo, index }] : [],
    );
    if (!removed.length) return 0;
    const index = this.index;
    // Keep the complete comparison order after it collapses to a single photo.
    // Batches remain arrays for the history UI; metadata belongs to the array.
    if (this.comparison.length && !this.comparisonOrder) {
      this.comparisonOrder = [...this.comparison];
    }
    removed.comparisonOrder = this.comparisonOrder;
    this.history.push(removed);
    const gone = new Set(removed.map((item) => item.photo.id));
    this.photos = this.photos.filter((photo) => !gone.has(photo.id));
    gone.forEach((id) => this.selected.delete(id));
    this.comparison = this.comparison.filter((id) => !gone.has(id));
    if (this.comparison.length < 2) this.comparison = [];
    if (gone.has(this.current)) {
      this.current = this.photos[Math.min(index, this.photos.length - 1)]?.id;
    }
    this.anchor = this.current;
    this.rangeBase = null;
    return removed.length;
  }

  restore(index = this.history.length - 1) {
    const batch = this.history.splice(index, 1)[0];
    if (!batch) return;
    for (const item of batch) {
      this.photos.splice(
        Math.min(item.index, this.photos.length),
        0,
        item.photo,
      );
    }
    this.photos.sort(
      (a, b) => this.original.indexOf(a) - this.original.indexOf(b),
    );
    this.current = batch[0].photo.id;
    this.anchor = this.current;
    this.rangeBase = null;
    if (batch.comparisonOrder) {
      this.comparisonOrder = batch.comparisonOrder;
      const available = new Set(this.photos.map((photo) => photo.id));
      const comparison = this.comparisonOrder.filter((id) => available.has(id));
      this.comparison = comparison.length >= 2 ? comparison : [];
    }
  }
}
