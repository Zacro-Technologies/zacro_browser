'use strict';
// Negotiate the host-only ABI on the actual profile session. Never infer native
// support from an Electron version, environment flag, manifest or persisted state.
const STOCK_CAPABILITIES = Object.freeze({
  version: 0,
  activeTab: false,
  reviewedPermissions: false,
  userScripts: false,
  fontSettings: false,
});
function negotiateEngineCapabilities(session) {
  try {
    const api = session?.extensions,
      value = api?.getZacroCapabilities?.();
    if (
      value?.version !== 1 ||
      value.reviewedPermissions !== true ||
      typeof api.setZacroReviewedPermissions !== 'function' ||
      typeof api.grantZacroActiveTab !== 'function' ||
      typeof api.setZacroUserScriptsEnabled !== 'function' ||
      typeof api.resetZacroExtensionState !== 'function'
    )
      return STOCK_CAPABILITIES;
    return Object.freeze({
      version: 1,
      reviewedPermissions: true,
      activeTab: value.activeTab === true,
      userScripts: value.userScripts === true,
      fontSettings:
        value.fontSettings === true &&
        typeof api.setZacroFontPreferences === 'function' &&
        typeof api.getZacroFontList === 'function' &&
        typeof api.getZacroFontPreferences === 'function',
    });
  } catch {
    return STOCK_CAPABILITIES;
  }
}
module.exports = { STOCK_CAPABILITIES, negotiateEngineCapabilities };
