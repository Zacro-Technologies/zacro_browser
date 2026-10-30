'use strict';

const { cleanSplitRatio } = require('../core/split-groups.cjs');

const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));
const finite = (value, fallback) => (Number.isFinite(value) ? value : fallback);

function browserLayout({
  width,
  height,
  sidebarWidth = 224,
  panelWidth = 0,
  contentTop = 36,
  pageGutter = 8,
  split = false,
  splitRatio = 0.5,
}) {
  width = Math.max(1, Math.round(finite(width, 1440)));
  height = Math.max(1, Math.round(finite(height, 940)));
  const gutter = Math.round(clamp(finite(pageGutter, 8), 4, 20));
  // Transient widths below 200 animate the sidebar; persisted widths retain
  // their separate 200px minimum. Every canvas edge keeps the same gutter.
  const sidebar = Math.round(
    clamp(finite(sidebarWidth, 224), 0, Math.min(380, Math.max(0, width - 240 - gutter * 2))),
  );
  const left = sidebar + gutter;
  const right = Math.round(clamp(finite(panelWidth, 0), 0, Math.max(0, width - sidebar - 240 - gutter * 2)));
  const available = Math.max(1, width - left - right - gutter);
  // The sidebar owns navigation in the compact layout. Only the Windows
  // caption rail, hidden-sidebar toolbar or an active Find row reserve height.
  const top = Math.min(
    Number.isInteger(contentTop) && contentTop >= 4 && contentTop <= 20
      ? gutter
      : [36, 40].includes(contentTop)
        ? contentTop
        : 36,
    height - 1,
  );
  const gap = 6;
  const secondaryVisible = split && available >= gap + 2;
  const splitWidth = available - gap;
  const minimumPane = Math.min(160, Math.floor(splitWidth / 2));
  const firstWidth = secondaryVisible
    ? clamp(Math.floor(splitWidth * cleanSplitRatio(splitRatio)), minimumPane, splitWidth - minimumPane)
    : available;
  return {
    primary: { x: left, y: top, width: firstWidth, height: Math.max(1, height - top - gutter) },
    secondary: secondaryVisible
      ? {
          x: left + firstWidth + gap,
          y: top,
          width: available - firstWidth - gap,
          height: Math.max(1, height - top - gutter),
        }
      : null,
    peek: (() => {
      const pageHeight = Math.max(1, height - top - gutter);
      const insetX = Math.min(112, Math.max(32, Math.round(available * 0.12)));
      const rightInset = Math.max(48, insetX);
      const insetY = Math.min(40, Math.max(20, Math.round(pageHeight * 0.04)));
      return {
        x: left + insetX,
        y: top + insetY,
        width: Math.max(1, available - insetX - rightInset),
        height: Math.max(1, pageHeight - insetY * 2),
      };
    })(),
  };
}

function peekMotionBounds(target, origin, progress, phase, full) {
  const amount = clamp(finite(progress, 1), 0, 1);
  const start = phase === 'expanding' ? target : origin || target;
  const end = phase === 'expanding' ? full : target;
  return Object.fromEntries(
    ['x', 'y', 'width', 'height'].map((key) => [
      key,
      Math.round(start[key] + (end[key] - start[key]) * amount),
    ]),
  );
}

function sameBounds(left, right) {
  return Boolean(left && right && ['x', 'y', 'width', 'height'].every((key) => left[key] === right[key]));
}

// Repeated state publications must not hide and show the focused native page.
function presentView(view, previous, next, parent = null) {
  let attached = Boolean(previous?.attached);
  // Hidden native children can remain reachable through platform accessibility
  // trees. Remove them from that hierarchy while retaining the living page.
  if (parent && next.visible && !attached) {
    parent.addChildView(view);
    attached = true;
  }
  if (next.bounds && !sameBounds(previous?.bounds, next.bounds)) view.setBounds(next.bounds);
  if (previous?.visible !== next.visible) view.setVisible(next.visible);
  if (parent && !next.visible && !next.retainAttachment && attached) {
    parent.removeChildView(view);
    attached = false;
  }
  return { visible: next.visible, bounds: next.bounds || previous?.bounds || null, attached };
}

function resolveSplit(pair, tabs, activeTabId, spaceId) {
  if (!pair || pair.length !== 2 || pair[0] === pair[1] || !pair.includes(activeTabId)) return null;
  if (tabs.find((tab) => tab.id === pair[0])?.profileId !== tabs.find((tab) => tab.id === pair[1])?.profileId)
    return null;
  if (
    !pair.every((id) =>
      tabs.some(
        (tab) =>
          tab.id === id &&
          (tab.spaceId === spaceId || tab.favorite) &&
          tab.url !== 'zacro://newtab' &&
          !tab.closed,
      ),
    )
  )
    return null;
  return { leftId: pair[0], rightId: pair[1], otherId: pair[0] === activeTabId ? pair[1] : pair[0] };
}

function restoreWindowPlacement(saved = {}, workAreas = []) {
  const areas = workAreas.filter(
    (area) => Number.isFinite(area.x) && Number.isFinite(area.y) && area.width > 0 && area.height > 0,
  );
  const fallback = { x: 0, y: 0, width: 1920, height: 1080 };
  const width = clamp(finite(saved.width, 1440), 560, 7680);
  const height = clamp(finite(saved.height, 940), 420, 4320);
  const intersection = (area) =>
    Math.max(0, Math.min(saved.x + width, area.x + area.width) - Math.max(saved.x, area.x)) *
    Math.max(0, Math.min(saved.y + height, area.y + area.height) - Math.max(saved.y, area.y));
  const positioned = Number.isFinite(saved.x) && Number.isFinite(saved.y);
  const target = positioned
    ? [...areas].sort((a, b) => intersection(b) - intersection(a))[0] || fallback
    : areas[0] || fallback;
  const size = { width: Math.min(width, target.width), height: Math.min(height, target.height) };
  const visible = positioned && intersection(target) > 0;
  return {
    width: Math.round(size.width),
    height: Math.round(size.height),
    x: Math.round(
      visible
        ? clamp(saved.x, target.x, target.x + target.width - size.width)
        : target.x + (target.width - size.width) / 2,
    ),
    y: Math.round(
      visible
        ? clamp(saved.y, target.y, target.y + target.height - size.height)
        : target.y + (target.height - size.height) / 2,
    ),
    maximized: saved.maximized === true,
  };
}

module.exports = { peekMotionBounds, browserLayout, presentView, resolveSplit, restoreWindowPlacement };
