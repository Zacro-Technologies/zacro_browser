chrome.runtime.onInstalled.addListener(() => chrome.storage.local.set({installed: true}));
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message === 'acceptance') {
    chrome.storage.local.get('installed', value => reply({background: true, installed: value.installed === true}));
    return true;
  }
});
