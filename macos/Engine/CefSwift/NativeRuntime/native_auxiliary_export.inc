// Optional versioned private embedding ABI. The opaque request-context pointer
// is borrowed, never dereferenced in Swift, and must be an existing CEF object.
// Unlike a DevTools transport this remains callable after all WebContents close.
extern "C" CEF_EXPORT int cef_zacro_auxiliary_admission_v1(
    int operation, void* borrowed_context, uint64_t high, uint64_t low,
    extensions::NativeWebAuthAdmissionState* output) {
  if (!CEF_CURRENTLY_ON_UIT()) return -10;
  Profile* profile = nullptr;
  if (borrowed_context) {
    auto* raw = static_cast<cef_request_context_0_t*>(borrowed_context);
    if (!raw->base.base.add_ref) return -11;
    raw->base.base.add_ref(&raw->base.base);
    CefRefPtr<CefRequestContext> context = CefRequestContextCppToC_Unwrap(raw);
    if (!context) return -11;
    auto* impl = static_cast<CefRequestContextImpl*>(context.get());
    auto* existing = impl->GetInitializedBrowserContextForNativeAdmission();
    if (!existing) return -12;
    profile = Profile::FromBrowserContext(existing);
  }
  return static_cast<int>(extensions::UpdateNativeWebAuthAdmission(
      static_cast<extensions::NativeWebAuthAdmissionOperation>(operation),
      profile, high, low, output));
}
