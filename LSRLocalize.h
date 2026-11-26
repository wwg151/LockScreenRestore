#pragma once

#import <Foundation/Foundation.h>

// The setting is shared by the preference pane and the tweak's wallpaper UI.

static NSString *const kLSRLanguageDomain = @"com.aronsz26.lockscreenrestore";
static NSString *const kLSRLanguageKey = @"uiLanguage";

// "zh" or "en", whatever was picked in the settings pane.
static inline NSString *LSRLanguageOverride(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)kLSRLanguageKey,
        (__bridge CFStringRef)kLSRLanguageDomain);
    NSString *language = value ? (__bridge_transfer NSString *)value : nil;
    return [language isKindOfClass:[NSString class]] && language.length ? language : nil;
}

// "zh" or "en": the picked language, English until something is picked.
static inline NSString *LSRUILanguageCode(void) {
    return [LSRLanguageOverride() isEqualToString:@"zh"] ? @"zh" : @"en";
}

static inline NSDictionary<NSString *, NSString *> *LSRReadStrings(NSString *bundlePath, NSString *code, NSString *table) {
    NSString *folder = [code isEqualToString:@"zh"] ? @"zh-Hans.lproj" : @"en.lproj";
    NSString *path = [[bundlePath stringByAppendingPathComponent:folder]
        stringByAppendingPathComponent:[table stringByAppendingPathExtension:@"strings"]];
    return path ? ([NSDictionary dictionaryWithContentsOfFile:path] ?: @{}) : @{};
}
