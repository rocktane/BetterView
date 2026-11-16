import { Library } from "./model.mjs";
import photos from "./photos.json";
import {
  centeredGeometry,
  centerFromOffset,
  centerForZoom,
  clamp,
} from "./geometry.mjs";
// Cache only in-flight decodes, never retain decoded Image objects indefinitely.
const loading = new Map();
function loadFull(photo) {
  if (loading.has(photo.src)) return loading.get(photo.src);
  if (loading.size >= 4) return Promise.resolve(null);
  const image = new Image();
  image.src = photo.src;
  const promise = image
    .decode()
    .then(() => photo.src)
    .catch(() => null)
    .finally(() => {
      loading.delete(photo.src);
    });
  loading.set(photo.src, promise);
  return promise;
}
const visibleViewers = new Set();
let activeViewer = null;
for (const root of document.querySelectorAll("[data-viewer]")) {
  const interactive = root.dataset.interactive === "true",
    model = new Library(
      photos.map((photo) => ({
        ...photo,
        ...Object.fromEntries(
          ["src", "preview", "thumb"].map((key) => [
            key,
            `${(root.dataset.base || "/").replace(/\/$/, "")}/${photo[key].replace(/^\//, "")}`,
          ]),
        ),
        responsive: photo.responsive?.map((item) => ({
          ...item,
          src: `${(root.dataset.base || "/").replace(/\/$/, "")}/${item.src.replace(/^\//, "")}`,
        })),
      })),
    ),
    stage = root.querySelector("[data-stage]"),
    strip = root.querySelector("[data-thumbnails]"),
    film = root.querySelector("[data-film]");
  function initialComparison() {
    if (root.dataset.comparison !== "true") return;
    model.selected = new Set(model.photos.slice(0, 3).map((p) => p.id));
    model.compare();
  }
  initialComparison();
  if (interactive) {
    new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        visibleViewers.add(root);
        activeViewer ??= root;
      } else {
        visibleViewers.delete(root);
        if (activeViewer === root)
          activeViewer = visibleViewers.values().next().value || null;
      }
    }).observe(root);
    for (const event of ["pointerdown", "focusin"])
      root.addEventListener(event, () => {
        if (visibleViewers.has(root)) activeViewer = root;
      });
  }
  let zoom = 1,
    af = false,
    afCentered = false,
    info = true,
    pan = { x: 0.5, y: 0.5 },
    hover = null,
    pointer = null,
    timer,
    drag,
    gesture;
  const say = (text) => {
    root.querySelector("[data-toast]").textContent = text;
    clearTimeout(timer);
    timer = setTimeout(
      () => (root.querySelector("[data-toast]").textContent = ""),
      2200,
    );
  };
  const escape = () => {
    if (zoom > 1) {
      zoom = 1;
      af = false;
      pan = { x: 0.5, y: 0.5 };
    } else if (model.comparison.length) {
      model.comparison = [];
      model.comparisonOrder = null;
    } else {
      model.selected.clear();
      model.rangeBase = null;
    }
  };
  function layoutStage() {
    const ids = model.comparison.length
      ? model.comparison.slice(0, 4)
      : [model.current];
    const visible = ids
      .map((id) => model.photos.find((p) => p.id === id))
      .filter(Boolean);
    const maxRatio = Math.max(...photos.map((p) => p.width / p.height));
    const fullscreen = document.fullscreenElement === root;
    const rootStyle = getComputedStyle(root);
    const available =
      root.clientWidth -
      parseFloat(rootStyle.paddingLeft) -
      parseFloat(rootStyle.paddingRight);
    const rail =
      ids.length > 1
        ? parseFloat(
            getComputedStyle(stage).getPropertyValue(
              "--comparison-actions-height",
            ),
          ) || 0
        : 0;
    const gap = 3;
    const rows = ids.length > 2 ? 2 : 1;
    const columns = ids.length > 1 ? 2 : 1;
    const ratios = Array.from({ length: columns }, (_, col) =>
      Math.max(
        ...visible
          .filter((_, i) => i % columns === col)
          .map((p) => p.width / p.height),
        0.1,
      ),
    );
    const sum = ratios.reduce((a, b) => a + b, 0);
    const photoHeight = Math.max(
      1,
      Math.min(
        ((fullscreen ? window.innerHeight * 0.72 : 560) -
          rows * rail -
          (rows - 1) * gap) /
          rows,
        (available - (columns - 1) * gap) / (ids.length > 1 ? sum : maxRatio),
      ),
    );
    const height = rows * (photoHeight + rail) + (rows - 1) * gap;
    stage.style.height = `${height}px`;
    stage.style.width = `${ids.length > 1 ? photoHeight * sum + (columns - 1) * gap : photoHeight * (visible[0]?.width / visible[0]?.height || 1)}px`;
    stage.style.maxWidth = "100%";
    stage.style.aspectRatio = "auto";
    stage.style.gridTemplateColumns = ratios.map((r) => `${r}fr`).join(" ");
    stage.style.gridTemplateRows = `repeat(${rows}, minmax(0, 1fr))`;
    stage.querySelectorAll(".slot").forEach((slot) => {
      const p = model.photos.find((p) => p.id === Number(slot.dataset.id));
      slot.style.width = `${(photoHeight * p.width) / p.height}px`;
      slot.style.height = `${photoHeight + rail}px`;
      slot.style.justifySelf = "center";
      const img = slot.querySelector("img");
      img.sizes = `${Math.ceil((photoHeight * p.width) / p.height)}px`;
    });
  }
  function photoHeight(slot) {
    return (
      slot.clientHeight -
      (model.comparison.length > 1
        ? parseFloat(
            getComputedStyle(stage).getPropertyValue(
              "--comparison-actions-height",
            ),
          ) || 0
        : 0)
    );
  }
  function transform() {
    stage.classList.toggle("zoomed", zoom > 1);
    stage.querySelectorAll(".slot").forEach((slot) => {
      const photo = model.photos.find((p) => p.id === Number(slot.dataset.id));
      const focus = afCentered && af ? photo.focus : pan;
      const g = centeredGeometry(
        slot.clientWidth,
        photoHeight(slot),
        photo.width / photo.height,
        zoom,
        focus,
      );
      const img = slot.querySelector("img");
      const width = `${g.width / zoom}px`,
        height = `${g.height / zoom}px`;
      if (img.style.width !== width) img.style.width = width;
      if (img.style.height !== height) img.style.height = height;
      img.style.transform = `translate(calc(-50% + ${g.x}px),calc(-50% + ${g.y}px)) scale(${zoom})`;
      if (zoom > 1 && img.dataset.full !== "true") {
        img.dataset.full = "true";
        loadFull(photo).then((src) => {
          if (
            src &&
            img.isConnected &&
            zoom > 1 &&
            Number(slot.dataset.id) === photo.id
          ) {
            img.removeAttribute("srcset");
            img.src = src;
          }
        });
      }
      if (zoom === 1 && img.dataset.full === "true") {
        img.dataset.full = "false";
        const preview = new Image();
        preview.sizes = img.sizes;
        if (photo.responsive)
          preview.srcset = photo.responsive
            .map((item) => `${item.src} ${item.width}w`)
            .join(", ");
        preview.src = photo.preview;
        preview
          .decode()
          .then(() => {
            if (zoom === 1 && Number(slot.dataset.id) === photo.id) {
              img.src = preview.currentSrc || photo.preview;
              if (photo.responsive)
                img.srcset = photo.responsive
                  .map((item) => `${item.src} ${item.width}w`)
                  .join(", ");
            }
          })
          .catch(() => {});
      }
      const marker = slot.querySelector(".marker");
      if (marker) {
        marker.hidden = !af;
        marker.style.left = `calc(50% + ${g.x + (photo.focus.x - 0.5) * g.width}px)`;
        marker.style.top = `calc(50% + ${g.y + (photo.focus.y - 0.5) * g.height - (slot.clientHeight - photoHeight(slot)) / 2}px)`;
      }
    });
    stage.querySelectorAll(".zoom-label").forEach((x) => {
      x.hidden = zoom <= 1;
      x.textContent = `${Math.round(zoom * 100)} %`;
    });
  }
  function zoomAt(value, clientX = pointer?.x, clientY = pointer?.y) {
    const slot =
      stage.querySelector(`[data-id="${hover}"]`) ||
      stage.querySelector(".slot");
    if (!slot) return;
    const photo = model.photos.find((p) => p.id === Number(slot.dataset.id));
    const r = slot.getBoundingClientRect();
    const g = centeredGeometry(
      r.width,
      photoHeight(slot),
      photo.width / photo.height,
      zoom,
      afCentered && af ? photo.focus : pan,
    );
    const next = clamp(value, 1, 8),
      factor = next / zoom,
      x = (clientX ?? r.left + r.width / 2) - r.left - r.width / 2,
      y =
        (clientY ?? r.top + photoHeight(slot) / 2) -
        r.top -
        photoHeight(slot) / 2;
    pan = centerForZoom(g, factor, x, y);
    zoom = next;
    af = false;
    if (zoom === 1) pan = { x: 0.5, y: 0.5 };
    transform();
  }
  function render() {
    // Persistent nodes keep their focus; return focus to the viewer only when
    // rendering removes the focused thumbnail or comparison action.
    const focused = document.activeElement;
    const hadFocus = root.contains(focused);
    const comparisonHint = root.querySelector("[data-comparison-hint]");
    if (comparisonHint) comparisonHint.hidden = model.comparison.length < 2;

    const ids = model.comparison.length
      ? model.comparison.slice(0, 4)
      : [model.current];
    if (!ids.includes(hover)) {
      hover = null;
      pointer = null;
    }
    stage.querySelector(".fallback-photo")?.remove();
    root.querySelector("[data-fallback-note]")?.remove();
    stage.classList.toggle("comparing", ids.length > 1);
    stage.classList.toggle("many", ids.length > 2);
    const existing = new Map(
      [...stage.querySelectorAll(".slot")].map((slot) => [
        Number(slot.dataset.id),
        slot,
      ]),
    );
    stage.querySelector(".empty")?.remove();
    for (const [id, slot] of existing) if (!ids.includes(id)) slot.remove();
    for (const id of ids) {
      const p = model.photos.find((p) => p.id === id);
      if (!p) continue;
      if (
        existing.has(id) &&
        (ids.length === 1 || existing.get(id).querySelector(".slot-actions"))
      ) {
        const slot = existing.get(id);
        slot
          .querySelectorAll(".info,.position")
          .forEach((el) => (el.hidden = !info));
        slot.querySelector(".position").textContent =
          `${model.photos.indexOf(p) + 1} / ${model.photos.length}`;
        if (ids.length === 1) slot.querySelector(".slot-actions")?.remove();
        stage.append(slot);
        continue;
      }
      existing.get(id)?.remove();
      const slot = document.createElement("div");
      slot.className = "slot";
      slot.dataset.id = id;
      slot.style.backgroundImage = `url("${p.thumb}")`;
      slot.style.backgroundSize = "contain";
      slot.style.backgroundPosition = "center";
      slot.style.backgroundRepeat = "no-repeat";
      slot.innerHTML = `<img src="${p.preview}" alt="${p.alt}" loading="lazy" decoding="async" draggable="false"><div class="traffic" aria-hidden="true"><i></i><i></i><i></i></div>${`<div class="overlay info"><strong>${p.locked ? "🔒 " : ""}${p.name}</strong><span>ISO 100 &nbsp;·&nbsp; 1/800 s &nbsp;·&nbsp; f/8.0 &nbsp;·&nbsp; 35 mm</span><span>19 septembre 2026 à 11:21</span></div><div class="overlay position">${model.photos.indexOf(p) + 1} / ${model.photos.length}</div>`}<div class="overlay zoom-label"></div><div class="marker" aria-label="Point AF illustratif"></div>`;
      slot
        .querySelectorAll(".info,.position")
        .forEach((el) => (el.hidden = !info));
      const image = slot.querySelector("img");
      image.width = p.width;
      image.height = p.height;
      image.sizes = `${Math.ceil(stage.clientWidth / (ids.length > 1 ? 2 : 1))}px`;
      if (p.responsive)
        image.srcset = p.responsive
          .map((item) => `${item.src} ${item.width}w`)
          .join(", ");
      image.onerror = () => {
        image.onerror = null;
        image.removeAttribute("srcset");
        image.src = p.thumb;
        say(`Aperçu indisponible : ${p.name}`);
      };
      if (ids.length > 1) {
        slot.querySelector(".traffic").remove();
        const actions = document.createElement("div");
        actions.className = "slot-actions";
        for (const [label, run] of [
          ["Corbeille", () => remove([id])],
          [
            "Garder celle-ci",
            () => remove(model.comparison.slice(0, 4).filter((x) => x !== id)),
          ],
        ]) {
          const b = document.createElement("button");
          b.textContent = label;
          b.onclick = (e) => {
            e.stopPropagation();
            run();
          };
          actions.append(b);
        }
        slot.append(actions);
      }
      slot.onpointerenter = () => (hover = id);
      slot.onpointermove = (e) => {
        if (e.clientY < slot.getBoundingClientRect().top + photoHeight(slot)) {
          hover = id;
          pointer = { x: e.clientX, y: e.clientY };
        } else pointer = null;
      };
      slot.onpointerleave = () => {
        if (hover === id) {
          hover = null;
          pointer = null;
        }
      };
      stage.append(slot);
    }
    if (!model.photos.length)
      stage.innerHTML =
        '<div class="empty">Toutes les photos ont été triées.<br>Annulez ou recommencez pour continuer.</div>';
    const oldThumbs = new Map(
      [...strip.children].map((node) => [Number(node.dataset.id), node]),
    );
    for (const [id, node] of oldThumbs)
      if (!model.photos.some((p) => p.id === id)) node.remove();
    model.photos.forEach((p, i) => {
      let wrapper = oldThumbs.get(p.id);
      if (!wrapper) {
        wrapper = document.createElement("div");
        wrapper.className = "thumb";
        wrapper.dataset.id = p.id;
        const b = document.createElement("button");
        b.type = "button";
        b.className = "thumb-photo";
        const img = document.createElement("img");
        img.src = p.thumb;
        img.alt = "";
        img.loading = "lazy";
        img.width = p.width;
        img.height = p.height;
        b.append(img);
        if (p.locked) {
          const lock = document.createElement("span");
          lock.className = "lock";
          lock.textContent = "🔒";
          lock.setAttribute("aria-hidden", "true");
          b.append(lock);
        }
        b.onclick = (e) => {
          model.go(
            model.photos.findIndex((photo) => photo.id === p.id),
            e.shiftKey,
            e.metaKey || e.ctrlKey,
          );
          render();
        };
        const check = document.createElement("button");
        check.type = "button";
        check.className = "selection-toggle";
        check.dataset.selectionToggle = "";
        check.onclick = () => {
          model.selected.has(p.id)
            ? model.selected.delete(p.id)
            : model.selected.add(p.id);
          model.rangeBase = null;
          model.anchor = p.id;
          render();
        };
        wrapper.append(b, check);
        strip.append(wrapper);
      }
      const b = wrapper.querySelector(".thumb-photo"),
        check = wrapper.querySelector(".selection-toggle");
      const selected = model.selected.has(p.id);
      wrapper.classList.toggle("current", p.id === model.current);
      wrapper.classList.toggle("selected", selected);
      wrapper.classList.toggle("burst", !!p.burst);
      b.setAttribute("aria-label", `${p.name}${p.locked ? ", protégée" : ""}`);
      b.setAttribute("aria-current", p.id === model.current ? "true" : "false");
      // CSS sizes thumbnails at each breakpoint using the intrinsic image ratio.
      check.innerHTML = selected
        ? '<span class="check" aria-hidden="true">✓</span>'
        : "";
      check.setAttribute(
        "aria-label",
        `${selected ? "Désélectionner" : "Sélectionner"} ${p.name}`,
      );
      check.setAttribute("aria-pressed", String(selected));
      wrapper.classList.toggle("selected", selected);
    });
    strip.classList.toggle("has-selection", model.selected.size > 0);
    const announcement = root.querySelector("[data-announcement]");
    const message = model.photos.length
      ? `${model.photos.find((p) => p.id === model.current)?.name}, ${model.index + 1} sur ${model.photos.length}`
      : "Aucune photo";
    if (announcement && announcement.textContent !== message)
      announcement.textContent = message;
    layoutStage();
    transform();
    for (const [name, on] of Object.entries({
      single: model.comparison.length < 2,
      comparison: model.comparison.length > 1,
      info,
      strip: !film.hidden,
      zoom: zoom > 1,
      focus: af,
      compare: model.comparison.length > 1,
      select: model.selected.has(model.current),
    })) {
      root
        .querySelectorAll(`[data-action="${name}"]`)
        .forEach((button) => button.setAttribute("aria-pressed", String(on)));
    }
    root
      .querySelectorAll('[data-action="comparison"],[data-action="compare"]')
      .forEach((button) => {
        button.disabled = model.selected.size < 2;
      });
    const active = strip.querySelector(".current");
    if (active) {
      const left =
        active.offsetLeft - strip.clientWidth / 2 + active.clientWidth / 2;
      strip.scrollLeft = Math.max(0, left);
    }
    root
      .querySelectorAll('[data-action="undo"]')
      .forEach((button) =>
        button.toggleAttribute("disabled", !model.history.length),
      );
    if (hadFocus && !focused.isConnected) root.focus({ preventScroll: true });
  }
  function remove(ids) {
    const locked = model.photos.some((p) => ids.includes(p.id) && p.locked);
    const n = model.remove(ids);
    say(
      n
        ? `${n} photo${n > 1 ? "s" : ""} à la corbeille${locked ? " · photo protégée conservée" : ""}`
        : "Photo protégée : suppression refusée",
    );
    render();
  }
  function history() {
    const dialog = root.querySelector("[data-history]"),
      list = root.querySelector("[data-history-list]");
    list.replaceChildren();
    if (!model.history.length) list.textContent = "Aucune suppression.";
    model.history.forEach((batch, i) => {
      const row = document.createElement("article"),
        img = document.createElement("img"),
        label = document.createElement("span"),
        b = document.createElement("button");
      img.src = batch[0].photo.thumb;
      img.loading = "lazy";
      img.alt = "";
      label.textContent = `${batch.length} photo(s) · ${batch[0].photo.name}`;
      b.textContent = "Restaurer";
      b.onclick = () => {
        model.restore(i);
        render();
        history();
      };
      row.append(img, label, b);
      list.append(row);
    });
    if (!dialog.open) dialog.showModal();
    else if (!dialog.contains(document.activeElement))
      dialog
        .querySelector("[data-close],button")
        ?.focus({ preventScroll: true });
  }
  function action(name) {
    if (["compare", "comparison"].includes(name) && model.selected.size < 2) {
      say("Sélectionnez au moins deux photos pour comparer.");
      return;
    }
    switch (name) {
      case "previous":
        model.move(-1);
        break;
      case "next":
        model.move(1);
        break;
      case "select":
        model.toggle();
        break;
      case "single":
        model.comparison = [];
        model.comparisonOrder = null;
        zoom = 1;
        af = false;
        pan = { x: 0.5, y: 0.5 };
        break;
      case "comparison":
        model.compare();
        zoom = 1;
        af = false;
        pan = { x: 0.5, y: 0.5 };
        break;
      case "compare":
        if (model.comparison.length) {
          model.comparison = [];
          model.comparisonOrder = null;
        } else model.compare();
        zoom = 1;
        break;
      case "delete":
        remove(
          model.comparison.slice(0, 4).includes(hover)
            ? [hover]
            : model.selected.size
              ? [...model.selected]
              : [model.current],
        );
        return;
      case "undo":
        model.restore();
        break;
      case "zoom":
        zoomAt(zoom > 1 ? 1 : 2);
        break;
      case "focus":
        af = !af;
        afCentered = af;
        zoom = af ? 2 : 1;
        pan = { x: 0.5, y: 0.5 };
        break;
      case "info":
        info = !info;
        break;
      case "strip":
        film.hidden = !film.hidden;
        break;
      case "history":
        history();
        return;
      case "reset":
        say("");
        model.reset();
        initialComparison();
        zoom = 1;
        af = false;
        pan = { x: 0.5, y: 0.5 };
        film.hidden = false;

        break;
      case "fullscreen":
        if (document.fullscreenElement) document.exitFullscreen();
        else
          root
            .requestFullscreen?.()
            .catch(() =>
              say("Le plein écran est indisponible dans ce navigateur."),
            );
        return;
    }
    render();
  }
  root.querySelectorAll("[data-action]").forEach(
    (b) =>
      (b.onclick = () => {
        action(b.dataset.action);
        if (!root.querySelector("dialog[open]"))
          root.focus({ preventScroll: true });
      }),
  );
  root
    .querySelector("[data-close]")
    ?.addEventListener("click", () => root.querySelector("dialog").close());
  const releaseKeys = () =>
    root
      .querySelectorAll("kbd.is-held")
      .forEach((key) => key.classList.remove("is-held"));
  root.querySelectorAll("kbd").forEach((key) => {
    if (!key.dataset.key)
      key.dataset.key =
        { "←": "arrowleft", "→": "arrowright", "⌫": "backspace" }[
          key.textContent.trim()
        ] || key.textContent.trim().toLowerCase();
  });
  function animateKeys(event) {
    root.querySelectorAll("kbd").forEach((key) => {
      if (
        (key.dataset.key === event.key.toLowerCase() &&
          (key.closest('[data-action="undo"]')
            ? event.metaKey || event.ctrlKey
            : !event.metaKey && !event.ctrlKey)) ||
        (key.dataset.key === "meta" && (event.metaKey || event.ctrlKey))
      )
        key.classList.add("is-held");
    });
  }
  document.addEventListener("keyup", releaseKeys);
  window.addEventListener("blur", releaseKeys);
  root.addEventListener("focusout", releaseKeys);
  document.addEventListener("keydown", (e) => {
    if (
      !interactive ||
      activeViewer !== root ||
      document.querySelector("dialog[open]") ||
      e.defaultPrevented ||
      e.target.closest(
        "summary,input,textarea,select,[contenteditable]:not([contenteditable=false])",
      ) ||
      (e.target.closest("button,a") && [" ", "Enter"].includes(e.key))
    )
      return;
    animateKeys(e);
    const key = e.key.toLowerCase(),
      cmd = e.metaKey || e.ctrlKey;
    let handled = true;
    if (
      e.repeat &&
      ["s", " ", "c", "x", "backspace", "delete", "z", "i", "b", "a"].includes(
        key,
      )
    ) {
      e.preventDefault();
      return;
    }
    if (cmd && key === "z") model.restore();
    else if (cmd && key === "y") {
      history();
      e.preventDefault();
      return;
    } else if (
      [
        "arrowright",
        "arrowdown",
        "arrowleft",
        "arrowup",
        "pageup",
        "pagedown",
        "home",
        "end",
      ].includes(key)
    ) {
      const offset = ["arrowright", "arrowdown"].includes(key)
        ? 1
        : ["arrowleft", "arrowup"].includes(key)
          ? -1
          : key === "pageup"
            ? -10
            : key === "pagedown"
              ? 10
              : key === "home"
                ? -model.photos.length
                : model.photos.length;
      model.move(offset, e.shiftKey);
    } else if (cmd && !["+", "=", "-", "0"].includes(key)) handled = false;
    else if (key === "escape") escape();
    else if (key === "a") {
      action("focus");
      e.preventDefault();
      return;
    } else if (["+", "="].includes(key)) zoomAt(zoom * 1.25);
    else if (key === "-") zoomAt(zoom / 1.25);
    else if (key === "0") {
      zoom = 1;
      af = false;
      pan = { x: 0.5, y: 0.5 };
    } else {
      const names = {
        s: "select",
        " ": "select",
        c: "compare",
        x: "delete",
        backspace: "delete",
        delete: "delete",
        z: "zoom",
        i: "info",
        b: "strip",
      };
      if (names[key]) {
        action(names[key]);
        e.preventDefault();
        return;
      } else handled = false;
    }
    if (handled) {
      e.preventDefault();
      render();
    }
  });
  if (interactive) {
    stage.addEventListener("pointerdown", (e) => {
      if (e.target.closest("button") || e.button !== 0) return;
      root.focus({ preventScroll: true });
      stage.setPointerCapture(e.pointerId);
      const slot = e.target.closest(".slot");
      if (!slot) return;
      const p = model.photos.find((p) => p.id === Number(slot.dataset.id));
      const g = centeredGeometry(
        slot.clientWidth,
        photoHeight(slot),
        p.width / p.height,
        zoom,
        afCentered && af ? p.focus : pan,
      );
      drag = {
        x: e.clientX,
        y: e.clientY,
        px: g.x,
        py: g.y,
        geometry: g,
        moved: false,
      };
    });
    stage.addEventListener("pointermove", (e) => {
      if (!drag) return;
      const dx = e.clientX - drag.x,
        dy = e.clientY - drag.y;
      if (Math.hypot(dx, dy) > 4) drag.moved = true;
      if (zoom > 1) {
        afCentered = false;
        pan = centerFromOffset(drag.geometry, drag.px + dx, drag.py + dy);
        transform();
      }
    });
    stage.addEventListener("pointerup", (e) => {
      if (!drag) return;
      const click = !drag.moved;
      drag = null;
      if (click) zoomAt(zoom > 1 ? 1 : 2, e.clientX, e.clientY);
    });
    stage.addEventListener("pointercancel", () => (drag = null));
    stage.addEventListener(
      "wheel",
      (e) => {
        if (e.ctrlKey) {
          e.preventDefault();
          if (!gesture)
            zoomAt(zoom * Math.exp(-e.deltaY * 0.01), e.clientX, e.clientY);
          return;
        }
        if (zoom <= 1) return;
        e.preventDefault();
        const slot =
          stage.querySelector(`[data-id="${hover}"]`) ||
          stage.querySelector(".slot");
        const p = model.photos.find((p) => p.id === Number(slot.dataset.id));
        const g = centeredGeometry(
          slot.clientWidth,
          photoHeight(slot),
          p.width / p.height,
          zoom,
          afCentered && af ? p.focus : pan,
        );
        afCentered = false;
        pan = centerFromOffset(g, g.x - e.deltaX, g.y - e.deltaY);
        transform();
      },
      { passive: false },
    );
    stage.addEventListener(
      "gesturestart",
      (e) => {
        e.preventDefault();
        gesture = { zoom };
      },
      { passive: false },
    );
    stage.addEventListener(
      "gesturechange",
      (e) => {
        e.preventDefault();
        if (gesture) zoomAt(gesture.zoom * e.scale, e.clientX, e.clientY);
      },
      { passive: false },
    );
    stage.addEventListener(
      "gestureend",
      (e) => {
        e.preventDefault();
        gesture = null;
      },
      { passive: false },
    );
  }

  document.addEventListener("fullscreenchange", () => {
    layoutStage();
    transform();
  });
  render();
  new ResizeObserver(() => {
    render();
  }).observe(root);
}
