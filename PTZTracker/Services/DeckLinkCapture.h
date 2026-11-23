#include <CoreVideo/CoreVideo.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The caller owns the returned capture and must close it.
void *PTZDeckLinkOpen(const char **errorMessage);
CVPixelBufferRef PTZDeckLinkCopyFrame(void *capture) CF_RETURNS_RETAINED;
void PTZDeckLinkClose(void *capture);

#ifdef __cplusplus
}
#endif
