'use strict';

// Groups describe saved organization; visibility is derived from the selected
// tab separately, so switching tabs or Spaces never tears a group down.
function cleanSplitGroups(groups, tabs, spaces) {
  const tabMap = new Map(tabs.map((tab) => [tab.id, tab]));
  const spaceMap = new Map(spaces.map((space) => [space.id, space]));
  const usedTabs = new Set();
  const usedIds = new Set();
  const result = [];
  for (const group of Array.isArray(groups) ? groups.slice(0, 500) : []) {
    if (
      !group ||
      typeof group.id !== 'string' ||
      !/^[a-zA-Z0-9_-]{1,100}$/.test(group.id) ||
      usedIds.has(group.id)
    )
      continue;
    const space = spaceMap.get(group.spaceId);
    if (
      !space ||
      !Array.isArray(group.tabIds) ||
      group.tabIds.length !== 2 ||
      group.tabIds[0] === group.tabIds[1]
    )
      continue;
    if (
      !group.tabIds.every((id) => {
        const tab = tabMap.get(id);
        return (
          tab &&
          !tab.closed &&
          !usedTabs.has(id) &&
          tab.profileId === space.profileId &&
          (tab.spaceId === space.id || tab.favorite)
        );
      })
    )
      continue;
    result.push({ id: group.id, spaceId: space.id, tabIds: [...group.tabIds] });
    usedIds.add(group.id);
    for (const id of group.tabIds) usedTabs.add(id);
  }
  return result;
}

module.exports = { cleanSplitGroups };
