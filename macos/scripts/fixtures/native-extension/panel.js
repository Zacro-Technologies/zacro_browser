/* Runs in Chromium's real SIDE_PANEL extension context, never a normal tab. */
const instance = crypto.randomUUID();
const draft = document.querySelector('#panel-draft');
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.type !== 'zacro-native-panel') return;
  if (message.draft !== undefined) draft.value = String(message.draft);
  chrome.windows.getCurrent().then(window => respond({ instance, draft: draft.value, windowID: window.id }));
  return true;
});
