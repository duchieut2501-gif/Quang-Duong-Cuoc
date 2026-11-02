#import <UIKit/UIKit.h>
#import "OverlayHUD.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "-hud") == 0) return RunOverlayHUD(argc, argv);
        if (argc > 1 && strcmp(argv[1], "-exit") == 0) return ExitOverlayHUD();
        if (argc > 1 && strcmp(argv[1], "-check") == 0) return CheckOverlayHUD();
        return UIApplicationMain(argc, argv, nil, @"AppDelegate");
    }
}
