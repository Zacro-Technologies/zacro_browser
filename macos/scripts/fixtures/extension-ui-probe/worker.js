chrome.runtime.onInstalled.addListener(() => chrome.action.setBadgeText({text: 'UI'}));
chrome.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message?.type !== 'zacro-ui-probe') return;
  chrome.storage.local.get('checks').then(async ({checks = 0}) => {
    await chrome.storage.local.set({checks: checks + 1});
    reply({ok: true, checks: checks + 1});
  });
  return true;
});
