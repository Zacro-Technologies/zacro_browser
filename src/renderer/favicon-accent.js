// Extract a stable accent from a small, decoded local favicon. Neutral pixels
// and transparent padding should not overpower a site's colored logo strokes.
export function faviconAccent(pixels) {
  const buckets = new Map();
  for (let index = 0; index + 3 < pixels.length; index += 4) {
    const [red, green, blue, alpha] = pixels.slice(index, index + 4);
    const maximum = Math.max(red, green, blue);
    const minimum = Math.min(red, green, blue);
    const saturation = maximum ? (maximum - minimum) / maximum : 0;
    if (alpha < 96 || maximum < 40 || minimum > 225 || saturation < 0.22) continue;
    const weight = (alpha / 255) * saturation;
    const key = `${red >> 5}:${green >> 5}:${blue >> 5}`;
    const bucket = buckets.get(key) || { weight: 0, red: 0, green: 0, blue: 0 };
    bucket.weight += weight;
    bucket.red += red * weight;
    bucket.green += green * weight;
    bucket.blue += blue * weight;
    buckets.set(key, bucket);
  }
  const dominant = [...buckets.values()].sort((a, b) => b.weight - a.weight)[0];
  if (!dominant || dominant.weight < 1.5) return null;
  return (
    '#' +
    ['red', 'green', 'blue']
      .map((channel) =>
        Math.round(dominant[channel] / dominant.weight)
          .toString(16)
          .padStart(2, '0'),
      )
      .join('')
  );
}
