// Bilingual text for the interface the tweak draws itself: the iOS 15 "Settings > Wallpaper"
// page and its preview sheets. The settings bundle keeps its own text in
// Resources/<language>.lproj/*.strings; these strings are compiled in because the tweak runs in
// SpringBoard, Preferences and MediaRemoteUI, where that bundle is not always loaded.
//
// The language is the one picked with the globe button in the settings pane ("uiLanguage" in
// com.aronsz26.lockscreenrestore, "zh" or "en"); with no choice it follows the device language.

#import <Foundation/Foundation.h>

static NSString *const kLSRLanguageDomain = @"com.aronsz26.lockscreenrestore";
static NSString *const kLSRLanguageKey = @"uiLanguage";

// "zh" or "en", whatever was picked in the settings pane.
static inline NSString *LSRLanguageOverride(void) {
    CFStringRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)kLSRLanguageKey,
        (__bridge CFStringRef)kLSRLanguageDomain);
    NSString *language = value ? (__bridge_transfer NSString *)value : nil;
    return [language isKindOfClass:[NSString class]] && language.length ? language : nil;
}

// "zh" or "en": the picked language, else the device's.
static inline NSString *LSRUILanguageCode(void) {
    NSString *picked = LSRLanguageOverride();
    if ([picked isEqualToString:@"zh"]) return @"zh";
    if ([picked isEqualToString:@"en"]) return @"en";
    NSString *language = [NSLocale preferredLanguages].firstObject ?: @"en";
    return [language hasPrefix:@"zh"] ? @"zh" : @"en";
}

static inline BOOL LSRUsesChinese(void) {
    return [LSRUILanguageCode() isEqualToString:@"zh"];
}

static inline NSString *LSRText(NSString *english, NSString *chinese) {
    return LSRUsesChinese() ? chinese : english;
}
