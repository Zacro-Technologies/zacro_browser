chrome.runtime.sendMessage('acceptance', reply => {
  if (reply?.background) document.documentElement.dataset.zacroExtension = 'service-worker-connected';
});
