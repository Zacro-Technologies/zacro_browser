document.getElementById('check').addEventListener('click', async () => {
  const status = document.getElementById('status');
  try {
    const result = await chrome.runtime.sendMessage({type: 'zacro-ui-probe'});
    status.textContent = result?.ok ? `Worker connected · check ${result.checks}` : 'Worker did not respond';
  } catch (error) { status.textContent = `Connection failed: ${error.message}`; }
});
