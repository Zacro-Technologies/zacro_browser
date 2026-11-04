#ifndef CCEF_EXTENSION_HOST_NAVIGATION_H_
#define CCEF_EXTENSION_HOST_NAVIGATION_H_
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  uint32_t size;
  uint32_t reserved;
  int32_t popup_id;
  int32_t disposition;
  int32_t user_gesture;
  int32_t owner_window_id;
  int32_t x, y, width, height;
  uint32_t feature_flags;
  const char* target_url;
  const char* frame_name;
  const char* source_extension_id;
} ccef_extension_host_navigation_request_t;
typedef struct {
  uint32_t size;
  uint32_t reserved;
  // owner_client is borrowed for this call. replacement_client transfers +1
  // to native CEF on success; it must be null on refusal.
  int (*prepare)(void* owner_client,
      const ccef_extension_host_navigation_request_t* request,
      void** replacement_client);
  void (*aborted)(void* owner_client, int32_t popup_id);
} ccef_extension_host_navigation_callbacks_t;
int ccef_extension_host_navigation_available(void);
int ccef_extension_host_navigation_install(
    const ccef_extension_host_navigation_callbacks_t* callbacks);
#ifdef __cplusplus
}
#endif
#endif
