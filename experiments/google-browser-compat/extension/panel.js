import {
  createWorkspace,
  project,
  preferences,
  webAddress,
  tabLabel,
  tabHost,
  GROUP_COLORS,
  PREFERENCE_KEY,
} from './workspace.mjs';

const $ = (selector) => document.querySelector(selector);
// A small subset of Zacro's existing vector vocabulary; no remote image fetches.
const paths = {
  search: 'M21 21l-5-5M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  arrow: 'M4 12h16m-6-6 6 6-6 6',
  plus: 'M12 5v14M5 12h14',
  down: 'm7 10 5 5 5-5',
  close: 'm6 6 12 12M18 6 6 18',
  info: 'M12 11v6M12 7h.01M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0',
  pin: 'm16 3 5 5-5 1-3 5 1 3-2 2-7-7 2-2 3 1 5-3zM5 19l-2 2',
  folder: 'M3 5h7l2 3h9v12H3z',
  edit: 'm16 3 5 5-12 12H4v-5zM13 6l5 5',
  reload: 'M20 4v6h-6M19.1 9a7.5 7.5 0 1 0 .4 5',
  system: 'M3 4h18v13H3zM8 21h8M12 17v4',
  light:
    'M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1 1M18 18l1 1M5 19l1-1M18 6l1-1',
  dark: 'M20 15A9 9 0 0 1 9 3a9 9 0 0 0 11 12',
};
function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(svg.namespaceURI, 'path');
  path.setAttribute('d', paths[name]);
  svg.append(path);
  return svg;
}
function iconButton(symbol, label, action) {
  const button = element('button', 'icon-button');
  button.type = 'button';
  button.setAttribute('aria-label', label);
  button.title = label;
  button.append(icon(symbol));
  button.addEventListener('click', action);
  return button;
}
for (const [selector, symbol] of Object.entries({
  '#search-icon': 'search',
  '#search-form button': 'arrow',
  '#new-workspace': 'plus',
  '#about': 'info',
  '#refresh': 'reload',
  '#empty-icon': 'folder',
  '#cancel-workspace': 'close',
  '#close-about': 'close',
}))
  $(selector).append(icon(symbol));

let controller;
let snapshot = { tabs: [], groups: [] };
let selection = 'all';
let currentPreferences = preferences();
let refreshGeneration = 0;
let timer;
let busy = false;
let editingGroup = null;
let dialogOpener;
const focusTargets = new Map();

function announce(message) {
  $('#status').textContent = message;
}
function remember(node, key) {
  node.dataset.focusKey = key;
  focusTargets.set(key, node);
  return node;
}
function setAppearance(value) {
  currentPreferences = preferences(value);
  document.documentElement.dataset.appearance = currentPreferences.appearance;
  const button = $('#appearance');
  const label = `Appearance: ${currentPreferences.appearance}. Change appearance`;
  button.setAttribute('aria-label', label);
  button.title = label;
  button.replaceChildren(icon(currentPreferences.appearance));
}
async function refresh() {
  if (!controller) return;
  const generation = ++refreshGeneration;
  try {
    const next = await controller.read();
    if (generation !== refreshGeneration) return;
    snapshot = next;
    render();
    $('#tab-list').setAttribute('aria-busy', 'false');
  } catch {
    if (generation === refreshGeneration) {
      $('#tab-list').setAttribute('aria-busy', 'false');
      announce('This browser window is unavailable. Reopen the workspace in a regular window.');
    }
  }
}
function scheduleRefresh() {
  clearTimeout(timer);
  timer = setTimeout(() => {
    void refresh();
  }, 40);
}
async function act(action, payload, success) {
  if (busy || !controller) return;
  busy = true;
  $('#tab-list').setAttribute('aria-busy', 'true');
  try {
    const result = await controller.dispatch(action, payload);
    if (result?.groupId !== undefined) selection = result.groupId;
    announce(success);
    return true;
  } catch {
    // Native API messages can contain full page URLs. Never log or surface them.
    announce('The change could not be completed. Check the current tabs and try again.');
    return false;
  } finally {
    busy = false;
    await refresh();
  }
}
function row(tab, groups) {
  const item = element('li', `tab-row${tab.active ? ' active' : ''}`);
  const label = tabLabel(tab);
  const main = remember(element('button', 'tab-main'), `tab:${tab.id}`);
  main.type = 'button';
  main.dataset.tabActivate = String(tab.id);
  main.setAttribute('aria-label', `Switch to ${label}`);
  if (tab.active) main.setAttribute('aria-current', 'page');
  main.append(element('span', 'tab-monogram', tabHost(tab).slice(0, 1).toLocaleUpperCase()));
  const text = element('span', 'tab-text');
  text.append(element('span', 'tab-title', label), element('span', 'tab-host', tabHost(tab)));
  main.append(text);
  main.addEventListener('click', () => {
    void act('activate', { tabId: tab.id }, 'Tab activated.');
  });
  const actions = element('div', 'tab-actions');
  const pin = remember(
    iconButton('pin', `${tab.pinned ? 'Unpin' : 'Pin'} ${label}`, () => {
      void act('pin', { tabId: tab.id }, tab.pinned ? 'Tab unpinned.' : 'Tab pinned.');
    }),
    `pin:${tab.id}`,
  );
  pin.classList.toggle('pinned', tab.pinned);
  pin.setAttribute('aria-pressed', String(tab.pinned));
  actions.append(pin);
  if (!tab.pinned) {
    const move = element('label', 'move-control');
    move.title = 'Move to workspace';
    move.append(icon('folder'));
    const select = remember(element('select'), `move:${tab.id}`);
    select.setAttribute('aria-label', `Workspace for ${label}`);
    select.append(new Option('Ungrouped', '-1'));
    for (const group of groups)
      select.append(new Option(group.title || 'Untitled workspace', String(group.id)));
    select.value = String(groups.some((group) => group.id === tab.groupId) ? tab.groupId : -1);
    select.addEventListener('change', () => {
      void act('move', { tabId: tab.id, groupId: Number(select.value) }, 'Tab moved.');
    });
    move.append(select);
    actions.append(move);
  }
  item.append(main, actions);
  return item;
}
function render() {
  const focused = document.activeElement?.dataset.focusKey;
  const scroll = $('#tab-list').scrollTop;
  focusTargets.clear();
  const projection = project(snapshot, { filter: selection, query: $('#search').value });
  selection = projection.selected;
  const filter = $('#workspace-filter');
  const filterOptions = [new Option('All tabs', 'all'), new Option('Ungrouped', 'ungrouped')];
  for (const group of snapshot.groups)
    filterOptions.push(new Option(group.title || 'Untitled workspace', String(group.id)));
  filter.replaceChildren(...filterOptions);
  filter.value = String(selection);
  const fragment = document.createDocumentFragment();
  const sections = [
    ...(projection.pins.length ? [{ id: 'pinned', title: 'Pinned', tabs: projection.pins }] : []),
    ...projection.sections,
  ];
  for (const group of sections) {
    const section = element('section', 'section');
    section.setAttribute('aria-label', group.title);
    const heading = element('div', 'section-heading');
    if (typeof group.id === 'number' && group.id >= 0) {
      const name = remember(element('button', 'group-name'), `group:${group.id}`);
      name.type = 'button';
      name.setAttribute('aria-label', `${group.collapsed ? 'Expand' : 'Collapse'} ${group.title}`);
      name.setAttribute('aria-expanded', String(!group.collapsed));
      const dot = element('i', 'group-dot');
      dot.dataset.color = group.color;
      name.append(icon('down'), dot, element('span', '', group.title));
      name.addEventListener('click', () => {
        void act('collapse-group', { groupId: group.id }, 'Workspace updated.');
      });
      const edit = remember(
        iconButton('edit', `Edit ${group.title}`, () => openWorkspaceDialog(group)),
        `edit:${group.id}`,
      );
      heading.append(name, element('span', 'count', String(group.tabs.length)), edit);
    } else {
      heading.append(element('h2', '', group.title), element('span', 'count', String(group.tabs.length)));
    }
    const list = element('ul', 'tab-rows');
    list.hidden = Boolean(group.collapsed);
    for (const tab of group.tabs) list.append(row(tab, snapshot.groups));
    section.append(heading, list);
    fragment.append(section);
  }
  $('#tab-list').replaceChildren(fragment);
  $('#tab-list').hidden = projection.count === 0;
  $('#empty').hidden = projection.count !== 0;
  const searching = Boolean($('#search').value.trim());
  $('#empty-title').textContent = searching ? 'No matching tabs' : 'Room for something new';
  $('#empty-detail').textContent = searching
    ? 'Try another title or website.'
    : 'Enter an HTTP or HTTPS address above.';
  $('#new-workspace').disabled = !snapshot.tabs.some((tab) => !tab.pinned);
  $('#tab-list').scrollTop = scroll;
  focusTargets.get(focused)?.focus({ preventScroll: true });
}
function openWorkspaceDialog(group = null) {
  editingGroup = group;
  dialogOpener = document.activeElement;
  $('#workspace-dialog-title').textContent = group ? 'Edit workspace' : 'New workspace';
  $('#save-workspace').textContent = group ? 'Save workspace' : 'Create workspace';
  $('#workspace-name').value = group?.title || '';
  $('#workspace-error').textContent = '';
  $('#starting-tab-field').hidden = Boolean(group);
  $('#starting-tab').required = !group;
  const candidates = snapshot.tabs.filter((tab) => !tab.pinned);
  $('#starting-tab').replaceChildren(...candidates.map((tab) => new Option(tabLabel(tab), String(tab.id))));
  const selected = candidates.find((tab) => tab.active) || candidates[0];
  if (selected) $('#starting-tab').value = String(selected.id);
  $('#group-colors').replaceChildren(
    ...GROUP_COLORS.map((color) => {
      const label = element('label');
      label.dataset.color = color;
      label.title = color;
      const input = element('input');
      input.type = 'radio';
      input.name = 'color';
      input.value = color;
      input.checked = color === (group?.color || 'purple');
      input.setAttribute('aria-label', color);
      label.append(input);
      return label;
    }),
  );
  $('#workspace-dialog').showModal();
  $('#workspace-name').focus();
}
$('#workspace-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (busy) return;
  const payload = {
    title: $('#workspace-name').value,
    color: $('#group-colors input:checked').value,
    ...(editingGroup ? { groupId: editingGroup.id } : { tabId: Number($('#starting-tab').value) }),
  };
  $('#save-workspace').disabled = true;
  const completed = await act(editingGroup ? 'edit-group' : 'create-group', payload, 'Workspace saved.');
  $('#save-workspace').disabled = false;
  if (completed) $('#workspace-dialog').close();
  else
    $('#workspace-error').textContent =
      'The browser may have changed this tab or group. Close this dialog and try again.';
});
$('#cancel-workspace').addEventListener('click', () => $('#workspace-dialog').close());
$('#workspace-dialog').addEventListener('close', () => {
  const key = dialogOpener?.dataset.focusKey;
  (focusTargets.get(key) || (dialogOpener?.isConnected ? dialogOpener : $('#new-workspace')))?.focus();
});
$('#new-workspace').addEventListener('click', () => openWorkspaceDialog());
$('#workspace-filter').addEventListener('change', (event) => {
  const value = event.target.value;
  selection = ['all', 'ungrouped'].includes(value) ? value : Number(value);
  render();
});
$('#search').addEventListener('input', () => {
  announce('');
  render();
});
$('#search-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const query = $('#search').value.trim();
  if (!query) return;
  let url;
  try {
    url = webAddress(query);
  } catch {
    const projection = project(snapshot, { filter: selection, query });
    const tab = [...projection.pins, ...projection.sections.flatMap((group) => group.tabs)][0];
    if (tab) await act('activate', { tabId: tab.id }, 'Tab activated.');
    else announce('Enter a complete http:// or https:// address, or choose a matching tab.');
    return;
  }
  if (await act('create', { url }, 'Page opened in a native tab.')) {
    $('#search').value = '';
    render();
  }
});
$('#refresh').addEventListener('click', async () => {
  await refresh();
  announce('Workspace refreshed.');
});
$('#appearance').addEventListener('click', async () => {
  if (!controller) return;
  const choices = ['system', 'light', 'dark'];
  const value = choices[(choices.indexOf(currentPreferences.appearance) + 1) % choices.length];
  try {
    setAppearance(await controller.savePreferences({ appearance: value }));
  } catch {
    announce('The appearance preference could not be saved.');
  }
});
$('#about').addEventListener('click', () => $('#about-dialog').showModal());
$('#close-about').addEventListener('click', () => $('#about-dialog').close());
$('#about-dialog').addEventListener('close', () => $('#about').focus());
document.addEventListener('keydown', (event) => {
  if (event.altKey || event.ctrlKey || event.metaKey || event.isComposing || $('dialog[open]')) return;
  const editing = event.target.matches('input,textarea,select');
  if (event.key === '/' && !editing) {
    event.preventDefault();
    $('#search').focus();
    return;
  }
  if (event.key === 'Escape' && $('#search').value) {
    event.preventDefault();
    $('#search').value = '';
    render();
    $('#search').focus();
    return;
  }
  const rows = [...document.querySelectorAll('[data-tab-activate]')].filter(
    (node) => node.getClientRects().length,
  );
  if (event.target === $('#search') && event.key === 'ArrowDown' && rows.length) {
    event.preventDefault();
    rows[0].focus();
    return;
  }
  const current = rows.indexOf(event.target);
  if (current < 0) return;
  const next =
    event.key === 'ArrowDown'
      ? Math.min(rows.length - 1, current + 1)
      : event.key === 'ArrowUp'
        ? current - 1
        : event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? rows.length - 1
            : null;
  if (next !== null) {
    event.preventDefault();
    (next < 0 ? $('#search') : rows[next]).focus();
  }
});

async function start() {
  // Bind this panel to its actual owning window, not a later last-focused one.
  const owner = await chrome.windows.getCurrent({ populate: false });
  if (owner.incognito || owner.type !== 'normal') throw new Error('A regular window is required.');
  controller = createWorkspace(chrome, owner.id);
  setAppearance(await controller.loadPreferences());
  for (const event of [
    chrome.tabs.onCreated,
    chrome.tabs.onUpdated,
    chrome.tabs.onRemoved,
    chrome.tabs.onMoved,
    chrome.tabs.onAttached,
    chrome.tabs.onDetached,
    chrome.tabs.onActivated,
    chrome.tabGroups.onCreated,
    chrome.tabGroups.onUpdated,
    chrome.tabGroups.onRemoved,
    chrome.tabGroups.onMoved,
  ])
    event.addListener(scheduleRefresh);
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes[PREFERENCE_KEY]) setAppearance(changes[PREFERENCE_KEY].newValue);
  });
  await refresh();
}
setAppearance(currentPreferences);
void start().catch(() => {
  $('#tab-list').setAttribute('aria-busy', 'false');
  $('#new-workspace').disabled = true;
  announce('Open this workspace from the extension button in a regular browser window.');
});
