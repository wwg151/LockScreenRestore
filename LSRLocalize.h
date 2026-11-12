// Bilingual text for the interface the tweak draws itself: the iOS 15 "Settings > Wallpaper"
// page and its preview sheets. The settings bundle keeps its own text in
// Resources/<language>.lproj/*.strings; these strings are compiled in because the tweak runs in
// SpringBoard, Preferences and MediaRemoteUI, where that bundle is not always loaded.
//
// A device set to Chinese gets the Chinese text, every other language the English one.

#import <Foundation/Foundation.h>

static inline BOOL LSRUsesChinese(void) {
    static BOOL chinese;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *language = [NSLocale preferredLanguages].firstObject ?: @"en";
        chinese = [language hasPrefix:@"zh"];
    });
    return chinese;
}

static inline NSString *LSRText(NSString *english, NSString *chinese) {
    return LSRUsesChinese() ? chinese : english;
}
