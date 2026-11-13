#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLE_DIR="$ROOT/src-tauri/gen/apple"

if [[ ! -d "$APPLE_DIR" ]]; then
  echo "src-tauri/gen/apple not found, initializing with tauri ios init..."
  (cd "$ROOT" && pnpm tauri ios init --ci)
fi

echo "Patching iOS Info.plist for ATS and orientations..."
for plist in $(find "$APPLE_DIR" -name "Info.plist" 2>/dev/null); do
  for key in "UISupportedInterfaceOrientations" "UISupportedInterfaceOrientations~iphone" "UISupportedInterfaceOrientations~ipad"; do
    /usr/libexec/PlistBuddy -c "Delete :${key}" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :${key} array" "$plist"
    /usr/libexec/PlistBuddy -c "Add :${key}:0 string UIInterfaceOrientationPortrait" "$plist"
    /usr/libexec/PlistBuddy -c "Add :${key}:1 string UIInterfaceOrientationLandscapeLeft" "$plist"
    /usr/libexec/PlistBuddy -c "Add :${key}:2 string UIInterfaceOrientationLandscapeRight" "$plist"
  done
  /usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$plist"
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$plist"
done

MAIN_MM="$APPLE_DIR/Sources/huangguo-client/main.mm"
echo "Patching $MAIN_MM for network permissions and safe-area layout..."
cat << 'EOF' > "$MAIN_MM"
#include "bindings/bindings.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// 1. 修复 iOS 国行网络权限弹窗未触发导致“无法连接”：
// 纯 Rust/BSD Socket 无法触发 iOS 系统的蜂窝数据授权提示（NEHelper/CoreTelephony），
// 启动时通过原生 CoreTelephony + NSURLSession 发起一次请求，唤醒系统授权弹窗。
static void trigger_ios_network_permission(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *ctHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
        if (ctHandle) {
            Class ctClass = NSClassFromString(@"CTCellularData");
            if (ctClass) {
                id ctInstance = [[ctClass alloc] init];
                SEL setNotifierSel = NSSelectorFromString(@"setCellularDataRestrictionDidUpdateNotifier:");
                if ([ctInstance respondsToSelector:setNotifierSel]) {
                    void (^notifier)(int) = ^(int state) {
                        NSLog(@"[HGhub] iOS Cellular data restricted state changed: %d", state);
                    };
                    typedef void (*SendMsgFn)(id, SEL, void (^)(int));
                    ((SendMsgFn)objc_msgSend)(ctInstance, setNotifierSel, notifier);
                }
            }
        }
        
        NSURLSession *session = [NSURLSession sharedSession];
        NSURL *pingUrl = [NSURL URLWithString:@"https://captive.apple.com/hotspot-detect.html"];
        NSURLSessionDataTask *task = [session dataTaskWithURL:pingUrl completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSLog(@"[HGhub] Native network authorization ping complete.");
        }];
        [task resume];
    });
}

// 2. 修复 WKWebView 底部空白区域（White Bar / Safe Area Gap）：
// iOS 11+ 下 WKWebView 默认 contentInsetAdjustmentBehavior 为 .automatic，
// 会自动给全屏应用注入 safe area 边距导致页面被向上推移或露出底部原生空白。
// 通过 Swizzle 将 contentInsetAdjustmentBehavior 设为 .never 并关闭橡皮筋滚动与白底。
@implementation WKWebView (HGhubSafeLayout)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [self class];
        
        SEL origSel = @selector(initWithFrame:configuration:);
        SEL swizSel = @selector(hghub_initWithFrame:configuration:);
        
        Method origMethod = class_getInstanceMethod(cls, origSel);
        Method swizMethod = class_getInstanceMethod(cls, swizSel);
        
        if (origMethod && swizMethod) {
            method_exchangeImplementations(origMethod, swizMethod);
        }
    });
}

- (instancetype)hghub_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    WKWebView *wv = [self hghub_initWithFrame:frame configuration:configuration];
    if (wv) {
        wv.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        wv.scrollView.bounces = NO;
        wv.opaque = NO;
        wv.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0];
        wv.scrollView.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0];
    }
    return wv;
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        trigger_ios_network_permission();
    }
    ffi::start_app();
    return 0;
}
EOF

echo "iOS patches successfully applied."
