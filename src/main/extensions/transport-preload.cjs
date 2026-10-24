'use strict';
const { contextBridge, ipcRenderer } = require('electron');
const channel = 'zacro:extension-transport:v1';
const connected = ipcRenderer.invoke(channel, { operation: 'connect' });
connected.catch(() => {});
// The capability is passed into a private native-listener closure, never put on
// the extension Window. Same-origin extension views cannot read a relay API.
contextBridge.executeInMainWorld({
  func: (transport) => {
    const sendToDocument = chrome.tabs.sendMessage.bind(chrome.tabs);
    chrome.runtime.onConnect.addListener((port) => {
      if (port.name !== 'zacro.extension.transport.v1') return;
      const native = port.sender;
      const sender = {
        id: native?.id,
        url: native?.url,
        origin: native?.origin,
        tabId: native?.tab?.id,
        frameId: native?.frameId,
        documentId: native?.documentId,
      };
      const bound = transport.bind(sender).then(async (binding) => {
        try {
          const live = await sendToDocument(
            binding.tabId,
            { namespace: 'zacro.extension.document.v1' },
            { documentId: binding.documentId },
          );
          if (live !== true) throw new Error('Native origin document is unavailable');
          await transport.activate(binding.originToken);
          return binding.originToken;
        } catch (error) {
          await transport.release(binding.originToken).catch(() => {});
          throw error;
        }
      });
      bound.catch(() => {});
      let disconnected = false;
      port.onDisconnect.addListener(() => {
        disconnected = true;
        bound.then((token) => transport.release(token)).catch(() => {});
      });
      port.onMessage.addListener(async (message) => {
        try {
          if (
            !message ||
            Object.keys(message).some((key) => !['id', 'method', 'args', 'hello'].includes(key)) ||
            !Number.isInteger(message.id)
          )
            throw new Error('Invalid transport envelope');
          const token = await bound;
          if (disconnected) throw new Error('Native origin port disconnected');
          const value =
            message.hello === true ? true : await transport.invoke(token, message.method, message.args);
          if (!disconnected) port.postMessage({ id: message.id, value });
        } catch (error) {
          if (!disconnected) port.postMessage({ id: message?.id, error: error.message });
        }
      });
    });
  },
  args: [
    {
      async bind(runtimeSender) {
        return ipcRenderer.invoke(channel, { operation: 'bind', token: await connected, runtimeSender });
      },
      async activate(originToken) {
        return ipcRenderer.invoke(channel, { operation: 'activate', token: await connected, originToken });
      },
      async invoke(originToken, method, args) {
        return ipcRenderer.invoke(channel, {
          operation: 'relay',
          token: await connected,
          originToken,
          method,
          args,
        });
      },
      async release(originToken) {
        return ipcRenderer.invoke(channel, { operation: 'release', token: await connected, originToken });
      },
    },
  ],
});
