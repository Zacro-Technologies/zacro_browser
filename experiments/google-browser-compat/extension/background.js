// Browser-owned action handling keeps opening the panel tied to a user gesture.
// No messages, page hooks, request interception or browsing-data persistence.
const configure = () => chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true });
chrome.runtime.onInstalled.addListener(() => {
  void configure();
});
chrome.runtime.onStartup.addListener(() => {
  void configure();
});
