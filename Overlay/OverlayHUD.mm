// Lớp chữ nổi đè lên mọi app (cần TrollStore).
// Phần khởi tạo cửa sổ hệ thống dựa trên TrollSpeed (MIT License, Lessica) — xem TROLLSPEED_LICENSE.

#import <UIKit/UIKit.h>
#import <spawn.h>
#import <errno.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#import "OverlayHUD.h"
#import "headers/pac_helper.h"
#import "headers/UIEventFetcher.h"
#import "headers/UIEventDispatcher.h"
#import "headers/UIApplication+Private.h"
#import "headers/BackboardServices.h"
#import "headers/SBSAccessibilityWindowHostingController.h"
#import "headers/UIWindow+Private.h"

extern "C" {
#import "headers/libproc.h"
#import "headers/kern_memorystatus.h"
}

extern "C" char **environ;

#define PID_PATH "/var/mobile/Library/Caches/com.quangduongcuoc.hud.pid"
#define NOTIFY_DISMISS "com.quangduongcuoc.hud.dismiss"
#define NOTIFY_OVERLAY "com.quangduongcuoc.overlay"
#define EXT_ID @"com.quangduongcuoc.app.broadcast"
#define GAP_POINTS 48.0  // ~8 mm
#define TEST_PATH @"/var/mobile/Library/Caches/com.quangduongcuoc.overlay.json"
#define STATUS_PATH @"/var/mobile/Library/Caches/com.quangduongcuoc.hud.status"

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, uid_t);

#pragma mark - Cửa sổ & giao diện

@interface QDHUDWindow : UIWindow
@end
@implementation QDHUDWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }   // chạm xuyên qua, không cản thao tác
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
@end

@interface QDHUDViewController : UIViewController
@end

static NSDate *MTime(NSString *path) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileModificationDate];
}
@implementation QDHUDViewController {
    UIView *_pill;
    UILabel *_title;
    UILabel *_sub;
    NSLayoutConstraint *_top;
    NSString *_extDir;
    NSTimer *_autoHide;
    NSDate *_lastSeen;
}

- (void)writeStatus {
    NSMutableString *st = [NSMutableString stringWithFormat:@"Chữ nổi đang chạy (pid %d).\n", getpid()];
    // Liệt kê mọi thư mục dữ liệu của extension để xem file overlay.json có ở đó không.
    NSString *root = @"/var/mobile/Containers/Data/PluginKitPlugin";
    NSArray *all = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    int n = 0;
    for (NSString *u in all) {
        NSString *dir = [root stringByAppendingPathComponent:u];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
            [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        NSString *ident = meta[@"MCMMetadataIdentifier"];
        if (![ident containsString:@"quangduongcuoc"]) continue;
        n++;
        NSString *f = [dir stringByAppendingPathComponent:@"Library/Caches/overlay.json"];
        NSDate *t = MTime(f);
        [st appendFormat:@"• %@: %@\n", [u substringToIndex:MIN(8, u.length)],
            t ? [NSString stringWithFormat:@"có dữ liệu, cập nhật %.0f giây trước", -t.timeIntervalSinceNow] : @"chưa có dữ liệu"];
    }
    [st appendFormat:@"Số thư mục extension: %d / tổng %lu", n, (unsigned long)all.count];
    [st writeToFile:STATUS_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
}


// Kiểm tra file mới 2 lần/giây (dự phòng nếu tín hiệu báo không tới).
- (void)poll {
    NSString *dir = [self extensionDir];
    NSString *extFile = dir ? [dir stringByAppendingPathComponent:@"Library/Caches/overlay.json"] : nil;
    NSString *best = nil; NSDate *bestT = nil;
    for (NSString *f in extFile ? @[extFile, TEST_PATH] : @[TEST_PATH]) {
        NSDate *t = MTime(f);
        if (t && (!bestT || [t compare:bestT] == NSOrderedDescending)) { best = f; bestT = t; }
    }
    if (!best || (_lastSeen && [bestT compare:_lastSeen] != NSOrderedDescending)) return;
    _lastSeen = bestT;
    [self apply:[NSData dataWithContentsOfFile:best]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.userInteractionEnabled = NO;
    self.view.backgroundColor = UIColor.clearColor;

    _pill = [UIView new];
    _pill.translatesAutoresizingMaskIntoConstraints = NO;
    _pill.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.88];
    _pill.layer.cornerRadius = 14;
    _pill.alpha = 0;
    [self.view addSubview:_pill];

    _title = [UILabel new];
    _title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    _title.textColor = UIColor.whiteColor;
    _title.textAlignment = NSTextAlignmentCenter;
    _title.adjustsFontSizeToFitWidth = YES;
    _sub = [UILabel new];
    _sub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _sub.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    _sub.textAlignment = NSTextAlignmentCenter;
    _sub.numberOfLines = 2;

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[_title, _sub]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 2;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [_pill addSubview:st];

    _top = [_pill.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:400];
    [NSLayoutConstraint activateConstraints:@[
        _top,
        [_pill.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_pill.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [st.topAnchor constraintEqualToAnchor:_pill.topAnchor constant:10],
        [st.bottomAnchor constraintEqualToAnchor:_pill.bottomAnchor constant:-10],
        [st.leadingAnchor constraintEqualToAnchor:_pill.leadingAnchor constant:14],
        [st.trailingAnchor constraintEqualToAnchor:_pill.trailingAnchor constant:-14],
    ]];

    int token;
    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(NOTIFY_OVERLAY, &token, dispatch_get_main_queue(), ^(int t) {
        [weakSelf poll];
    });
    _lastSeen = [NSDate date];   // bỏ qua dữ liệu cũ lúc mới bật
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [weakSelf poll]; }];
    [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *t) { [weakSelf writeStatus]; }];
    [self writeStatus];
}

// Tìm thư mục dữ liệu của extension "phát màn hình" (nơi nó ghi overlay.json).
- (NSString *)extensionDir {
    if (_extDir) return _extDir;
    NSString *root = @"/var/mobile/Containers/Data/PluginKitPlugin";
    for (NSString *u in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dir = [root stringByAppendingPathComponent:u];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
            [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        if ([meta[@"MCMMetadataIdentifier"] isEqualToString:EXT_ID] &&
            [NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"Library/Caches/overlay.json"]]) {
            _extDir = dir; break;
        }
    }
    return _extDir;
}

- (void)apply:(NSData *)d {
    if (!d) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![j isKindOfClass:NSDictionary.class]) return;

    [_autoHide invalidate];
    if (![j[@"show"] boolValue]) {
        [UIView animateWithDuration:0.2 animations:^{ self->_pill.alpha = 0; }];
        return;
    }
    _title.text = j[@"title"] ?: @"";
    _sub.text = j[@"sub"] ?: @"";
    _sub.hidden = _sub.text.length == 0;
    CGFloat h = UIScreen.mainScreen.bounds.size.height;
    _top.constant = MIN([j[@"y"] doubleValue] * h + GAP_POINTS, h - 220);
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.15 animations:^{ self->_pill.alpha = 1; }];
    // An toàn: tự ẩn sau 20 giây nếu không có lệnh ẩn.
    _autoHide = [NSTimer scheduledTimerWithTimeInterval:20 repeats:NO block:^(NSTimer *t) {
        [UIView animateWithDuration:0.2 animations:^{ self->_pill.alpha = 0; }];
    }];
}
@end

#pragma mark - Ứng dụng HUD (khung dựa trên TrollSpeed)

@interface QDHUDApplication : UIApplication
@end
@implementation QDHUDApplication
- (instancetype)init {
    if (self = [super init]) {
        int outToken;
        notify_register_dispatch(NOTIFY_DISMISS, &outToken, dispatch_get_main_queue(), ^(int token) {
            notify_cancel(token);
            [self terminateWithSuccess];
        });
        do {
            UIEventDispatcher *dispatcher = (UIEventDispatcher *)[self valueForKey:@"eventDispatcher"];
            if (!dispatcher) break;
            if ([dispatcher respondsToSelector:@selector(_installEventRunLoopSources:)]) {
                [dispatcher _installEventRunLoopSources:CFRunLoopGetMain()];
            } else {
                IMP runIMP = class_getMethodImplementation([self class], @selector(_run));
                if (!runIMP) break;
                uint32_t *p = (uint32_t *)make_sym_readable((void *)runIMP);
                void (*install)(id, SEL, CFRunLoopRef) = NULL;
                for (int i = 0; i < 0x140; i++) {
                    if (p[i] != 0xaa0003e2 || (p[i + 1] & 0xff000000) != 0xaa000000) continue;
                    uint32_t bl = p[i + 2];
                    if ((bl & 0xfc000000) != 0x94000000) continue;
                    int32_t off = bl & 0x03ffffff;
                    if (off & 0x02000000) off |= 0xfc000000;
                    off <<= 2;
                    uint64_t addr = (uint64_t)&p[i + 2] + off;
                    if (((*(uint32_t *)make_sym_readable((void *)addr)) & 0xff000000) != 0xb4000000) continue;
                    install = (void (*)(id, SEL, CFRunLoopRef))make_sym_callable((void *)addr);
                }
                if (!install) break;
                install(dispatcher, @selector(_installEventRunLoopSources:), CFRunLoopGetMain());
            }
            UIEventFetcher *fetcher = [[objc_getClass("UIEventFetcher") alloc] init];
            [dispatcher setValue:fetcher forKey:@"eventFetcher"];
            if ([fetcher respondsToSelector:@selector(setEventFetcherSink:)]) [fetcher setEventFetcherSink:dispatcher];
            else [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
            [self setValue:fetcher forKey:@"eventFetcher"];
        } while (NO);
    }
    return self;
}
@end

@interface QDHUDDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation QDHUDDelegate {
    SBSAccessibilityWindowHostingController *_hosting;
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[QDHUDWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [QDHUDViewController new];
    [self.window setWindowLevel:10000010.0];
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];

    _hosting = [[objc_getClass("SBSAccessibilityWindowHostingController") alloc] init];
    unsigned int ctx = [self.window _contextId];
    double level = [self.window windowLevel];
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:_hosting];
    [inv setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    [inv setArgument:&ctx atIndex:2];
    [inv setArgument:&level atIndex:3];
    [inv invoke];
    return YES;
}
@end

#pragma mark - Điểm vào

static void KeepAlive(pid_t me) {
    memorystatus_priority_properties_t props = { JETSAM_PRIORITY_CRITICAL, 0 };
    memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, me, 0, &props, sizeof(props));
    memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, me, -1, NULL, 0);
    memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, me, 0, NULL, 0);
    proc_track_dirty(me, 0);
}

int RunOverlayHUD(int argc, char *argv[]) {
    pid_t pid = getpid();
    [[NSString stringWithFormat:@"%d", pid] writeToFile:@PID_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    KeepAlive(pid);

    [UIScreen initialize];
    CFRunLoopGetCurrent();
    GSInitialize();
    BKSDisplayServicesStart();
    UIApplicationInitialize();
    UIApplicationInstantiateSingleton(objc_getClass("QDHUDApplication"));
    static id<UIApplicationDelegate> delegate = [[QDHUDDelegate alloc] init];
    [UIApplication.sharedApplication setDelegate:delegate];
    [UIApplication.sharedApplication _accessibilityInit];
    [NSRunLoop currentRunLoop];
    if (@available(iOS 15.0, *)) {
        GSEventInitialize(0);
        GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
    }
    [UIApplication.sharedApplication __completeAndRunAsPlugin];

    // SpringBoard khởi động lại (respring) -> mở lại HUD.
    static int sbToken;
    notify_register_dispatch("SBSpringBoardDidLaunchNotification", &sbToken, dispatch_get_main_queue(), ^(int token) {
        notify_cancel(token);
        SetOverlayEnabled(YES);
        kill(pid, SIGKILL);
    });
    CFRunLoopRun();
    return 0;
}

static pid_t ReadPid(void) {
    NSString *s = [NSString stringWithContentsOfFile:@PID_PATH encoding:NSUTF8StringEncoding error:nil];
    return s ? (pid_t)s.intValue : 0;
}

int ExitOverlayHUD(void) {
    pid_t p = ReadPid();
    if (p > 0) kill(p, SIGKILL);
    unlink(PID_PATH);
    return 0;
}

int CheckOverlayHUD(void) {
    pid_t p = ReadPid();
    return (p > 0 && (kill(p, 0) == 0 || errno == EPERM)) ? 1 : 0;
}

// Chạy chính file app này với tham số, dưới quyền root (TrollStore cho phép).
static int SpawnSelf(const char *arg, BOOL wait) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *path = (char *)calloc(1, size);
    _NSGetExecutablePath(path, &size);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    if (!wait) {
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    }
    pid_t child;
    const char *args[] = { path, arg, NULL };
    int rc = posix_spawn(&child, path, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);
    free(path);
    if (rc != 0) return -1;
    int status = 0;
    if (!wait) { waitpid(child, &status, WNOHANG); return 0; }
    while (waitpid(child, &status, 0) == -1 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

BOOL IsOverlayEnabled(void) { return SpawnSelf("-check", YES) == 1; }

NSString *OverlayStatus(void) {
    if (!CheckOverlayHUD()) return @"Chữ nổi chưa chạy.";
    return [NSString stringWithContentsOfFile:STATUS_PATH encoding:NSUTF8StringEncoding error:nil] ?: @"Chữ nổi đang khởi động…";
}

void TestOverlay(void) {
    NSDictionary *j = @{@"show": @YES, @"y": @0.45, @"title": @"Thử chữ nổi: 12,3 km • 25 phút", @"sub": @"Nếu thấy dòng này là chữ nổi đã chạy"};
    [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] writeToFile:TEST_PATH atomically:YES];
    notify_post(NOTIFY_OVERLAY);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[NSJSONSerialization dataWithJSONObject:@{@"show": @NO} options:0 error:nil] writeToFile:TEST_PATH atomically:YES];
        notify_post(NOTIFY_OVERLAY);
    });
}

void SetOverlayEnabled(BOOL on) {
    notify_post(NOTIFY_DISMISS);
    SpawnSelf("-exit", YES);
    if (on) SpawnSelf("-hud", NO);
}
