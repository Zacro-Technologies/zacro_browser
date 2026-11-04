// Private native producer boundary. These helpers deliberately live after
// CefClient's original generated wrapper-type specialization in this TU.
CefRefPtr<CefClient> ZacroWrapExtensionHostClient(void* transferred) {
  return CefClientCToCpp_Wrap(static_cast<cef_client_0_t*>(transferred));
}
void* ZacroUnwrapExtensionHostClient(CefRefPtr<CefClient> client) {
  return CefClientCToCpp_Unwrap(client);
}
NO_SANITIZE("cfi-icall") void ZacroReleaseExtensionHostClient(void* transferred) {
  if (!transferred) return;
  auto* raw = static_cast<cef_client_0_t*>(transferred);
  raw->base.release(&raw->base);
}
