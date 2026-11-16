export const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

// Center is shared in normalized image coordinates, independent of aspect ratio.
export function centeredGeometry(
  width,
  height,
  ratio,
  zoom,
  center = { x: 0.5, y: 0.5 },
) {
  const fit = Math.min(width / ratio, height);
  const w = fit * ratio * zoom;
  const h = fit * zoom;
  return {
    width: w,
    height: h,
    x: clamp(
      (0.5 - center.x) * w,
      -Math.max(0, (w - width) / 2),
      Math.max(0, (w - width) / 2),
    ),
    y: clamp(
      (0.5 - center.y) * h,
      -Math.max(0, (h - height) / 2),
      Math.max(0, (h - height) / 2),
    ),
  };
}

export function centerFromOffset(geometry, x, y) {
  return { x: 0.5 - x / geometry.width, y: 0.5 - y / geometry.height };
}

export function photoGeometry(
  width,
  height,
  ratio,
  zoom,
  pan,
  focus = { x: 0.5, y: 0.5 },
) {
  const g = centeredGeometry(width, height, ratio, zoom, focus);
  return centeredGeometry(width, height, ratio, zoom, {
    x: focus.x - pan.x / g.width,
    y: focus.y - pan.y / g.height,
  });
}

// Preserve the image point under a viewport-relative pointer while scaling.
export function centerForZoom(geometry, factor, x = 0, y = 0) {
  return centerFromOffset(
    { width: geometry.width * factor, height: geometry.height * factor },
    x - (x - geometry.x) * factor,
    y - (y - geometry.y) * factor,
  );
}
