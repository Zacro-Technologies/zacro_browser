#ifndef CCEF_AUXILIARY_ADMISSION_H_
#define CCEF_AUXILIARY_ADMISSION_H_
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  uint32_t size;
  uint32_t reserved;
  uint64_t high;
  uint64_t low;
  uint64_t requests;
  uint64_t presented;
  uint64_t unpresented;
} ccef_auxiliary_admission_state_t;
int ccef_auxiliary_admission_available(void);
// Borrowed context, optional only for process acquire or an existing lease.
int ccef_auxiliary_admission(int operation, void* context, uint64_t high,
                            uint64_t low, ccef_auxiliary_admission_state_t* result);
#ifdef __cplusplus
}
#endif
#endif
