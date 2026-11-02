/* The managed options page is a real extension document and native tab. */
const optionsInstance = crypto.randomUUID();
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.type !== "zacro-native-options") return;
  Promise.all([chrome.windows.getCurrent(), chrome.tabs.getCurrent()]).then(([window, tab]) => {
    respond({ instance: optionsInstance, window, tab, url: location.href,
      draft: document.querySelector("#options-draft").value });
  });
  return true;
});
