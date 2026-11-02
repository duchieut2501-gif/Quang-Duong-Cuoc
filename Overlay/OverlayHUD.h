#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bật/tắt lớp chữ nổi (tiến trình HUD chạy riêng, cần TrollStore).
BOOL IsOverlayEnabled(void);
void SetOverlayEnabled(BOOL on);

int RunOverlayHUD(int argc, char *argv[]);
int ExitOverlayHUD(void);
int CheckOverlayHUD(void);

#ifdef __cplusplus
}
#endif
