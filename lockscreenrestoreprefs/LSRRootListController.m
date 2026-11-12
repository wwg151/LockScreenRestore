#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import "../LSRLocalize.h"

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(NSUInteger)options targetURL:(NSURL *)targetURL;
@end

// SBSRelaunchActionOptionsFadeToBlackTransition
static const NSUInteger kLSRRelaunchFadeToBlack = 1 << 2;

// The one device the layout has been checked on so far.
static NSString *const kLSRTestedModel = @"iPhone14,2";

static NSString *LSRModelIdentifier(void) {
    size_t size = 0;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = malloc(size);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *model = [NSString stringWithUTF8String:machine];
    free(machine);
    return model;
}

// Every iPhone that runs iOS 16.
static NSString *LSRDeviceName(NSString *model) {
    NSDictionary<NSString *, NSString *> *names = @{
        @"iPhone10,1": @"iPhone 8", @"iPhone10,4": @"iPhone 8",
        @"iPhone10,2": @"iPhone 8 Plus", @"iPhone10,5": @"iPhone 8 Plus",
        @"iPhone10,3": @"iPhone X", @"iPhone10,6": @"iPhone X",
        @"iPhone11,2": @"iPhone XS", @"iPhone11,4": @"iPhone XS Max", @"iPhone11,6": @"iPhone XS Max",
        @"iPhone11,8": @"iPhone XR",
        @"iPhone12,1": @"iPhone 11", @"iPhone12,3": @"iPhone 11 Pro", @"iPhone12,5": @"iPhone 11 Pro Max",
        @"iPhone12,8": @"iPhone SE (2nd generation)",
        @"iPhone13,1": @"iPhone 12 mini", @"iPhone13,2": @"iPhone 12",
        @"iPhone13,3": @"iPhone 12 Pro", @"iPhone13,4": @"iPhone 12 Pro Max",
        @"iPhone14,4": @"iPhone 13 mini", @"iPhone14,5": @"iPhone 13",
        @"iPhone14,2": @"iPhone 13 Pro", @"iPhone14,3": @"iPhone 13 Pro Max",
        @"iPhone14,6": @"iPhone SE (3rd generation)",
        @"iPhone14,7": @"iPhone 14", @"iPhone14,8": @"iPhone 14 Plus",
        @"iPhone15,2": @"iPhone 14 Pro", @"iPhone15,3": @"iPhone 14 Pro Max",
    };
    return names[model] ?: model;
}

// The panel's text lives beside the bundle in en.lproj and zh-Hans.lproj: LSRText.strings holds
// the labels and footnotes of Root.plist, Localizable.strings the alerts and the language sheet.
// The language picked with the globe button wins over the device language (see LSRLocalize.h);
// Root.plist itself stays English and is never handed to Preferences' own localization, so what
// is on screen is exactly the table we choose.
static char kLSROriginalTextKey;

static void LSRSetPref(NSString *key, id value);

static NSBundle *LSRBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundle = [NSBundle bundleForClass:NSClassFromString(@"LSRRootListController")]
            ?: [NSBundle bundleWithIdentifier:@"com.aronsz26.lockscreenrestore.prefs"];
    });
    return bundle;
}

static NSDictionary *LSRStringsTable(NSString *name) {
    NSString *language = LSRUsesChinese() ? @"zh-Hans" : @"en";
    NSString *path = [LSRBundle() pathForResource:name ofType:@"strings" inDirectory:nil forLocalization:language];
    return path ? ([NSDictionary dictionaryWithContentsOfFile:path] ?: @{}) : @{};
}

static NSString *LSRLocalized(NSString *key) {
    return LSRStringsTable(@"Localizable")[key] ?: key;
}

// A small menu that hangs under the globe button and is only as wide as its longest entry;
// UIMenu is a fixed width, which looked too wide for two short language names.
@interface LSRLanguagePopoverController : UIViewController
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, weak) UIView *anchorView;
@property (nonatomic, copy) void (^selectionHandler)(NSInteger index);
@end

@interface LSRRootListController : PSListController
- (void)applyLanguage;
- (UIBarButtonItem *)languageButton;
- (void)showLanguagePopover:(UIButton *)sender;
- (void)selectLanguage:(NSString *)code;
@end

@implementation LSRLanguagePopoverController {
    UIVisualEffectView *_panel;
    NSMutableArray<UIButton *> *_rows;
    UIImageView *_check;
}

- (instancetype)init {
    if ((self = [super init])) {
        _rows = [NSMutableArray new];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    UIControl *outside = [[UIControl alloc] initWithFrame:self.view.bounds];
    outside.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [outside addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:outside];

    _panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    _panel.layer.cornerRadius = 13;
    _panel.layer.cornerCurve = kCACornerCurveContinuous;
    _panel.clipsToBounds = YES;
    [self.view addSubview:_panel];

    for (NSUInteger i = 0; i < self.titles.count; i++) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        row.tag = (NSInteger)i;
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        row.titleLabel.font = [UIFont systemFontOfSize:17];
        [row setTitle:self.titles[i] forState:UIControlStateNormal];
        [row setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [row addTarget:self action:@selector(choose:) forControlEvents:UIControlEventTouchUpInside];
        [_panel.contentView addSubview:row];
        [_rows addObject:row];

        if (i + 1 < self.titles.count) {
            UIView *line = [[UIView alloc] init];
            line.backgroundColor = [UIColor separatorColor];
            line.tag = 9000 + (NSInteger)i;
            [_panel.contentView addSubview:line];
        }
    }

    _check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
    _check.tintColor = self.view.tintColor;
    _check.contentMode = UIViewContentModeScaleAspectFit;
    _check.hidden = self.selectedIndex < 0;
    [_panel.contentView addSubview:_check];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat rowHeight = 44.0;
    CGFloat padding = 16.0;
    CGFloat checkmark = 26.0;
    UIFont *font = [UIFont systemFontOfSize:17];
    CGFloat widest = 0;
    for (NSString *title in self.titles) {
        widest = MAX(widest, [title sizeWithAttributes:@{NSFontAttributeName: font}].width);
    }
    CGFloat width = ceil(widest + padding * 2 + checkmark);
    CGFloat height = rowHeight * (CGFloat)self.titles.count;

    // Right under the button, centred on it and kept inside the screen.
    CGRect anchor = CGRectZero;
    if (self.anchorView.window) anchor = [self.anchorView.superview convertRect:self.anchorView.frame toView:self.view];
    CGFloat x = CGRectGetMidX(anchor) - width / 2.0;
    x = MAX(8.0, MIN(x, CGRectGetWidth(self.view.bounds) - width - 8.0));
    CGFloat y = anchor.size.height > 0 ? CGRectGetMaxY(anchor) + 6.0 : 120.0;
    _panel.frame = CGRectMake(round(x), round(y), width, height);

    for (NSUInteger i = 0; i < _rows.count; i++) {
        _rows[i].frame = CGRectMake(padding, rowHeight * (CGFloat)i, width - padding * 2, rowHeight);
        UIView *line = [_panel.contentView viewWithTag:9000 + (NSInteger)i];
        if (line) line.frame = CGRectMake(padding, rowHeight * (CGFloat)(i + 1), width - padding * 2, 0.5);
    }
    if (self.selectedIndex >= 0 && self.selectedIndex < (NSInteger)_rows.count) {
        _check.frame = CGRectMake(width - padding - 20, rowHeight * (CGFloat)self.selectedIndex + (rowHeight - 20) / 2.0, 20, 20);
    }
}

- (void)choose:(UIButton *)row {
    NSInteger index = row.tag;
    void (^handler)(NSInteger) = self.selectionHandler;
    [self dismissViewControllerAnimated:NO completion:^{
        if (handler) handler(index);
    }];
}

- (void)close {
    [self dismissViewControllerAnimated:NO completion:nil];
}

@end

@implementation LSRRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self applyLanguage];
    }
    return _specifiers;
}

- (void)applyLanguage {
    NSDictionary *table = LSRStringsTable(@"LSRText");
    for (PSSpecifier *specifier in _specifiers) {
        NSMutableDictionary *original = objc_getAssociatedObject(specifier, &kLSROriginalTextKey);
        if (!original) {
            original = [NSMutableDictionary new];
            for (NSString *key in @[@"label", @"footerText", @"title"]) {
                NSString *value = [specifier propertyForKey:key];
                if (value) original[key] = value;
            }
            objc_setAssociatedObject(specifier, &kLSROriginalTextKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [original enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            [specifier setProperty:(table[value] ?: value) forKey:key];
        }];
        // A cell takes its text from the specifier's name, not from the label property, so the
        // switch and group titles only follow the language through this.
        NSString *label = original[@"label"];
        if (label) specifier.name = table[label] ?: label;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [self languageButton];
}

// The button carries its own view so the menu knows where to hang from.
- (UIBarButtonItem *)languageButton {
    UIButton *globe = [UIButton buttonWithType:UIButtonTypeSystem];
    [globe setImage:[UIImage systemImageNamed:@"globe"] forState:UIControlStateNormal];
    globe.frame = CGRectMake(0, 0, 30, 30);
    [globe addTarget:self action:@selector(showLanguagePopover:) forControlEvents:UIControlEventTouchUpInside];
    return [[UIBarButtonItem alloc] initWithCustomView:globe];
}

- (void)showLanguagePopover:(UIButton *)sender {
    LSRLanguagePopoverController *popover = [LSRLanguagePopoverController new];
    popover.titles = @[@"中文", @"English"];
    popover.selectedIndex = LSRUsesChinese() ? 0 : 1;
    popover.anchorView = sender;
    __weak LSRRootListController *weakSelf = self;
    popover.selectionHandler = ^(NSInteger index) {
        [weakSelf selectLanguage:index == 0 ? @"zh" : @"en"];
    };
    [self presentViewController:popover animated:NO completion:nil];
}

// Chinese or English for this panel and the tweak's own screens. The choice is saved in the
// tweak's own preferences, so SpringBoard and the wallpaper page read the same language.
- (void)selectLanguage:(NSString *)code {
    LSRSetPref(kLSRLanguageKey, code);
    [self applyLanguage];
    [self reloadSpecifiers];
}

// The tweak reads the plist straight from disk when SpringBoard starts, but cfprefsd keeps
// changes in memory and writes the file whenever it likes (a respring could still see a state
// from hours ago). So write the file ourselves on every change: what cfprefsd has, plus the
// value that just changed. Rootless jailbreaks keep it under /var/jb.
static NSString *const kLSRDomain = @"com.aronsz26.lockscreenrestore";

static NSString *LSRPrefsFilePath(void) {
    NSString *name = [kLSRDomain stringByAppendingPathExtension:@"plist"];
    NSString *rootless = @"/var/jb/var/mobile/Library/Preferences";
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:rootless isDirectory:&isDir] && isDir) {
        return [rootless stringByAppendingPathComponent:name];
    }
    return [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:name];
}

static void LSRWritePrefsFile(NSString *changedKey, id changedValue) {
    CFStringRef domain = (__bridge CFStringRef)kLSRDomain;
    CFPreferencesAppSynchronize(domain);
    NSString *path = LSRPrefsFilePath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary new];
    CFArrayRef keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        NSDictionary *current = CFBridgingRelease(CFPreferencesCopyMultiple(keys, domain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        [prefs addEntriesFromDictionary:current];
        CFRelease(keys);
    }
    if (changedKey) {
        if (changedValue) prefs[changedKey] = changedValue;
        else [prefs removeObjectForKey:changedKey];
    }
    [prefs writeToFile:path atomically:YES];
}

// A value that has no row in Root.plist (the language): cfprefsd first, so the tweak reads it at
// once, then the file SpringBoard reads.
static void LSRSetPref(NSString *key, id value) {
    CFStringRef domain = (__bridge CFStringRef)kLSRDomain;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, domain);
    CFPreferencesAppSynchronize(domain);
    LSRWritePrefsFile(key, value);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    LSRWritePrefsFile([specifier propertyForKey:@"key"], value);
}

// Every switch and the Clock Size slider back to its default (the wallpapers picked in
// Settings > Wallpaper stay), then a respring so SpringBoard picks it up.
- (void)resetToDefaults {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LSRLocalized(@"Reset to Defaults")
        message:LSRLocalized(@"All switches and Clock Size go back to their defaults. Your wallpapers stay as they are. Your iPhone will respring.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LSRLocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LSRLocalized(@"Reset") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        CFStringRef domain = (__bridge CFStringRef)kLSRDomain;
        NSMutableArray<NSString *> *keys = [NSMutableArray new];
        for (PSSpecifier *specifier in [self specifiers]) {
            NSString *key = [specifier propertyForKey:@"key"];
            if (key.length) [keys addObject:key];
        }
        for (NSString *key in keys) CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, domain);
        CFPreferencesAppSynchronize(domain);
        NSString *path = LSRPrefsFilePath();
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (prefs) {
            [prefs removeObjectsForKeys:keys];
            [prefs writeToFile:path atomically:YES];
        }
        [self reloadSpecifiers];
        [self respring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)respring {
    LSRWritePrefsFile(nil, nil);
    SBSRelaunchAction *action = [SBSRelaunchAction actionWithReason:@"RestartRenderServer"
                                                            options:kLSRRelaunchFadeToBlack
                                                          targetURL:nil];
    [[FBSSystemService sharedService] sendActions:[NSSet setWithObject:action] withResult:nil];
}

// The tweak derives every size and position from the screen and SpringBoard's per-device
// lock screen metrics when SpringBoard starts. This shows what it will detect and recalculates.
- (void)fixPositions {
    UIScreen *screen = [UIScreen mainScreen];
    CGSize size = screen.bounds.size;
    NSString *model = LSRModelIdentifier();

    NSMutableString *message = [NSMutableString stringWithFormat:@"%@\n%.0f × %.0f pt @%.0fx\n\n",
        LSRDeviceName(model), MIN(size.width, size.height), MAX(size.width, size.height), screen.scale];
    [message appendString:LSRLocalized(@"Padlock, clock, date and Focus pill will be recalculated for this screen after a respring.")];
    if (![model isEqualToString:kLSRTestedModel]) {
        [message appendFormat:@"\n\n%@",
            LSRLocalized(@"This iPhone hasn't been tested yet. If something looks off, please open an issue on GitHub with a screenshot.")];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LSRLocalized(@"Fix Positions")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LSRLocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LSRLocalized(@"Respring") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self respring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
