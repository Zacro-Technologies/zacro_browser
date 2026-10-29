'use strict';

const DEFAULT_ARCHIVE_HOURS = 12;
const ARCHIVE_HOURS = Object.freeze([0, 1, 6, 12, 24, 48, 72, 168, 720]);
const validArchiveHours = (value) => ARCHIVE_HOURS.includes(value);

function defaultArchiveProfile(state) {
  return (
    state.profiles.find((profile) => profile.id === 'default' && !profile.private) ||
    state.profiles.find((profile) => !profile.private)
  );
}

function normalizeDefaultArchive(state) {
  const profile = defaultArchiveProfile(state);
  if (!profile) return;
  // The default is stored once. Promote older/imported primary-profile
  // overrides so no invisible choice can disagree with the Settings control.
  if (validArchiveHours(profile.archiveAfterHours))
    state.settings.archiveAfterHours = profile.archiveAfterHours;
  profile.archiveAfterHours = null;
}

function archiveHours(state, profileId) {
  const profile = state.profiles.find((item) => item.id === profileId);
  if (validArchiveHours(profile?.archiveAfterHours)) return profile.archiveAfterHours;
  return validArchiveHours(state.settings.archiveAfterHours)
    ? state.settings.archiveAfterHours
    : DEFAULT_ARCHIVE_HOURS;
}

function archiveCandidate(state, tab, now = Date.now()) {
  const hours = archiveHours(state, tab.profileId);
  return Boolean(
    hours &&
    !tab.pinned &&
    !tab.favorite &&
    !tab.folderId &&
    !tab.savedPeek &&
    !state.splitGroups?.some((group) => group.tabIds.includes(tab.id)) &&
    tab.id !== state.activeTabId &&
    Number.isFinite(tab.lastActiveAt) &&
    tab.lastActiveAt <= now - hours * 3600000,
  );
}

module.exports = {
  DEFAULT_ARCHIVE_HOURS,
  ARCHIVE_HOURS,
  validArchiveHours,
  defaultArchiveProfile,
  normalizeDefaultArchive,
  archiveHours,
  archiveCandidate,
};
