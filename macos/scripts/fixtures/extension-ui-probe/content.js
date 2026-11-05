const marker = document.createElement('div');
marker.id = 'zacro-extension-ui-probe';
marker.textContent = 'Extension content script active';
marker.style.cssText = 'position:fixed;bottom:16px;right:16px;padding:12px 16px;background:#164c3c;color:white;border-radius:10px;z-index:2147483647;font:14px system-ui';
(document.body || document.documentElement).append(marker);
