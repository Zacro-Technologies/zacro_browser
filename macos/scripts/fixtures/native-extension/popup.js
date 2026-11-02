/* An actual action popup must have a Chrome POPUP context and owning window. */
chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message?.type !== "zacro-native-close-popup") return;
  respond({ closing: true });
  setTimeout(() => window.close(), 0);
});
Promise.all([chrome.windows.getCurrent(), chrome.tabs.query({ active: true, currentWindow: true }),
  chrome.runtime.getContexts({ contextTypes: ['POPUP'] })]).then(async ([window, tabs, contexts]) => {
  await chrome.storage.local.set({ nativePopupResult: {
    instance: crypto.randomUUID(), windowID: window.id, tabIDs: tabs.map(tab => tab.id),
    contexts: contexts.filter(context => context.documentUrl === location.href)
  }});
});
