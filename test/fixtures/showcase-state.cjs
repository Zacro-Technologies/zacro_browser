'use strict';

const { createInitialState } = require('../../src/core/store.cjs');

// Explicit demo data for an isolated hands-on review profile. Public URLs are
// saved destinations, not fetched assets: session restoration loads only the
// active local journal until the reviewer selects another tab.
function createShowcaseState(localUrl) {
  const base = new URL(localUrl);
  if (base.protocol !== 'http:' || base.hostname !== '127.0.0.1')
    throw new Error('The showcase requires the local interactive fixture.');
  const now = Date.now();
  const state = createInitialState();
  const profileId = 'showcase-profile';
  const studio = 'showcase-studio';
  const personal = 'showcase-personal';
  const reading = 'showcase-reading';
  const journalUrl = new URL('/', base).href;
  const notesUrl = new URL('/notes', base).href;
  const tab = (id, title, url, options = {}) => ({
    id: `showcase-tab-${id}`,
    spaceId: studio,
    profileId,
    title,
    ...(url !== 'zacro://newtab' ? { customTitle: title } : {}),
    url,
    pinned: false,
    favorite: false,
    folderId: null,
    createdAt: now - 3600000,
    lastActiveAt: now - 600000,
    ...options,
  });

  state.profiles = [{ id: profileId, name: 'Demo profile', private: false }];
  state.spaces = [
    {
      id: studio,
      profileId,
      name: 'Design studio',
      color: '#486786',
      icon: 'code',
      theme: { secondaryColor: '#ac85a7', gradient: 65, grain: 24, opacity: 70, blur: 16 },
      lastActiveTabId: 'showcase-tab-journal',
    },
    {
      id: personal,
      profileId,
      name: 'Personal',
      color: '#a56545',
      icon: 'home',
      theme: { secondaryColor: '#e3b282', gradient: 60, grain: 15, opacity: 80, blur: 12 },
      lastActiveTabId: 'showcase-tab-personal',
    },
    {
      id: reading,
      profileId,
      name: 'Reading',
      color: '#416958',
      icon: 'book',
      theme: { secondaryColor: '#84a5af', gradient: 70, grain: 12, opacity: 85, blur: 8 },
      lastActiveTabId: 'showcase-tab-reading',
    },
  ];
  state.activeSpaceId = studio;
  state.activeTabId = 'showcase-tab-journal';
  state.folders = [
    { id: 'showcase-research', spaceId: studio, name: 'Research' },
    { id: 'showcase-project', spaceId: studio, name: 'Project' },
  ];
  state.tabs = [
    tab('github', 'GitHub', 'https://github.com/', { pinned: true, favorite: true }),
    tab('mdn', 'MDN', 'https://developer.mozilla.org/', { pinned: true, favorite: true }),
    tab('wikipedia', 'Wikipedia', 'https://www.wikipedia.org/', { pinned: true, favorite: true }),
    tab('arena', 'Are.na', 'https://www.are.na/', { pinned: true, favorite: true }),
    tab('arc', 'Arc · Focus', 'https://start.arc.net/find-focus', { folderId: 'showcase-research' }),
    tab('zen', 'Zen · Compact mode', 'https://docs.zen-browser.app/user-manual/compact-mode', {
      folderId: 'showcase-research',
    }),
    tab('repo', 'Zacro browser', 'https://github.com/Zacro-Technologies/zacro_browser', {
      folderId: 'showcase-project',
    }),
    tab('css', 'CSS reference', 'https://web.dev/learn/css', { folderId: 'showcase-project' }),
    tab('new', 'New tab', 'zacro://newtab'),
    tab('journal', 'Fieldnotes journal', journalUrl, { lastActiveAt: now }),
    tab('notes', 'The quiet web', notesUrl),
    tab('personal', 'New tab', 'zacro://newtab', { spaceId: personal }),
    tab('reading', 'New tab', 'zacro://newtab', { spaceId: reading }),
  ];
  state.bookmarks = [
    ['chrome', 'Chrome for developers', 'https://developer.chrome.com/'],
    ['web', 'web.dev', 'https://web.dev/'],
    ['figma', 'Figma Community', 'https://www.figma.com/community'],
    ['fonts', 'Google Fonts', 'https://fonts.google.com/'],
  ].map(([id, title, url]) => ({ id: `showcase-bookmark-${id}`, profileId, title, url, createdAt: now }));
  state.history = [
    {
      id: 'showcase-history-journal',
      profileId,
      title: 'Fieldnotes — A local browsing test',
      url: journalUrl,
      visitedAt: now - 60000,
    },
    {
      id: 'showcase-history-notes',
      profileId,
      title: 'The quiet web — Fieldnotes',
      url: notesUrl,
      visitedAt: now - 300000,
    },
  ];
  state.settings = { ...state.settings, theme: 'light', archiveAfterHours: 0, sidebarWidth: 224 };
  return state;
}

module.exports = { createShowcaseState };
