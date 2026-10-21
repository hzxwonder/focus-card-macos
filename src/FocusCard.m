// FocusCard · 专注卡片
// A focus/break timer for macOS: a floating card, a menu bar countdown, a completion overlay and a
// settings window. Single-file AppKit app. Build with scripts/build.sh.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <UserNotifications/UserNotifications.h>
#import <ServiceManagement/ServiceManagement.h>
#import <math.h>
#import <sys/resource.h>
#import <mach/mach.h>

#pragma mark - Localization

static BOOL gChinese = YES;
static NSString *T(NSString *zh, NSString *en) { return gChinese ? zh : en; }
static BOOL systemPrefersChinese(void) { return [(NSLocale.preferredLanguages.firstObject ?: @"zh-Hans").lowercaseString hasPrefix:@"zh"]; }
// Language order: FOCUSCARD_LANG (tests), then the app's Language setting ("zh", "en"; "system" or none = macOS language).
static void detectLanguage(NSString *setting) {
    NSString *forced = NSProcessInfo.processInfo.environment[@"FOCUSCARD_LANG"];
    if (forced.length) { gChinese = [forced.lowercaseString hasPrefix:@"zh"]; return; }
    if ([setting isEqualToString:@"zh"]) gChinese = YES; else if ([setting isEqualToString:@"en"]) gChinese = NO; else gChinese = systemPrefersChinese();
}

#pragma mark - Clock and timer model

// All time reads go through clockNow() so the tests can move time forward.
static double gClockOffset = 0;
static double clockNow(void) { return NSDate.date.timeIntervalSince1970 + gClockOffset; }

typedef struct { double remaining, deadline; } Countdown;
static NSInteger secondsLeft(Countdown c, double now) { return MAX(0, (NSInteger)ceil(c.deadline > 0 ? c.deadline - now : c.remaining)); }
static void startTimer(Countdown *c, double now) { if (!c->deadline && c->remaining > 0) c->deadline = now + c->remaining; }
static void pauseTimer(Countdown *c, double now) { if (c->deadline) c->remaining = MAX(0, c->deadline - now); c->deadline = 0; }
static BOOL finishTimer(Countdown *c, double now) {
    if (!c->deadline || c->deadline > now) return NO;
    c->remaining = c->deadline = 0; return YES;
}

static const NSInteger kMinMinutes = 1, kMaxMinutes = 180;
static const double kLateGrace = 60;   // A phase that ended more than this long ago completes silently.
static NSInteger boundedMinutes(NSInteger value, NSInteger fallback) { return value >= kMinMinutes && value <= kMaxMinutes ? value : fallback; }
static double boundedDouble(double value, double lo, double hi, double fallback) { return isfinite(value) && value >= lo && value <= hi ? value : fallback; }
static NSString *timeString(NSInteger seconds) { return [NSString stringWithFormat:@"%02ld:%02ld", (long)seconds / 60, (long)seconds % 60]; }
static NSString *dayKey(double t) {
    static NSDateFormatter *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat = @"yyyy-MM-dd"; });
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
}
static NSString *clockText(double t) {
    static NSDateFormatter *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm"; });
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
}
// Accepts ASCII and full-width digits with surrounding spaces. Returns -1 for anything else.
static NSInteger parseMinutes(NSString *text) {
    NSString *s = [[text stringByApplyingTransform:NSStringTransformFullwidthToHalfwidth reverse:NO] ?: text
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length == 0 || s.length > 4) return -1;
    for (NSUInteger i = 0; i < s.length; i++) if ([s characterAtIndex:i] < '0' || [s characterAtIndex:i] > '9') return -1;
    NSInteger v = s.integerValue;
    return v >= kMinMinutes && v <= kMaxMinutes ? v : -1;
}

#pragma mark - Preference keys

static NSString *const kFocus = @"minutes", *const kBreak = @"breakMinutes", *const kRest = @"rest", *const kStarted = @"started";
static NSString *const kRemaining = @"remaining", *const kEnd = @"endTime", *const kDuration = @"sessionDuration";
static NSString *const kAutoBreak = @"autoBreak", *const kAutoFocus = @"autoFocus", *const kNotify = @"notifications", *const kSound = @"sound";
static NSString *const kSoundName = @"soundName", *const kCompletion = @"completionStyle", *const kTheme = @"theme", *const kAmbient = @"ambientMotion";
static NSString *const kPinned = @"pinned", *const kOpacity = @"glassOpacity", *const kMenuTime = @"showMenuBarTime", *const kCardVisible = @"cardVisible", *const kCompact = @"compactCard";
static NSString *const kStatsDay = @"statsDay", *const kStatsSessions = @"statsSessions", *const kStatsSeconds = @"statsFocusSeconds";
static NSString *const kNotificationID = @"focuscard.phase";
static NSString *const kFrameName = @"FocusCardPositionV4";
static NSString *const kOverlay = @"overlay", *const kBanner = @"banner";
static NSString *const kLanguage = @"language";   // "system", "zh" or "en"
static NSString *const kLogin = @"_login";   // Draft-only key: the login item lives in the system, not in preferences.
static NSArray<NSString *> *settingKeys(void) {
    return @[kFocus, kBreak, kAutoBreak, kAutoFocus, kNotify, kSound, kSoundName, kCompletion, kTheme, kAmbient, kPinned, kOpacity, kMenuTime, kLanguage];
}
static NSArray<NSString *> *knownKeys(void) {
    return [settingKeys() arrayByAddingObjectsFromArray:@[kRest, kStarted, kRemaining, kEnd, kDuration, kCardVisible, kCompact, kStatsDay, kStatsSessions, kStatsSeconds]];
}

#pragma mark - Colors, themes and sounds

static NSColor *rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
static NSColor *hex(unsigned v, CGFloat a) { return rgb(((v >> 16) & 255) / 255.0, ((v >> 8) & 255) / 255.0, (v & 255) / 255.0, a); }
static NSColor *mix(NSColor *a, NSColor *b, CGFloat t) {   // t = share of b
    NSColor *x = [a colorUsingColorSpace:NSColorSpace.sRGBColorSpace], *y = [b colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return rgb(x.redComponent * (1 - t) + y.redComponent * t, x.greenComponent * (1 - t) + y.greenComponent * t,
               x.blueComponent * (1 - t) + y.blueComponent * t, x.alphaComponent * (1 - t) + y.alphaComponent * t);
}
// Screenshot rendering draws layer content (gradients, plates) with AppKit so that cacheDisplayInRect captures it.
static BOOL gSnapshot = NO;
static BOOL reduceMotion(void) { return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion; }

typedef NS_ENUM(NSInteger, Ambient) { AmbientDrift, AmbientRain, AmbientRipple, AmbientFrost, AmbientNone };

// A theme is a complete, checked palette: two gradients (focus, break), two accents, text colors and one ambient effect.
@interface Theme : NSObject
@property NSString *key, *zh, *en;
@property NSColor *focusTop, *focusBottom, *restTop, *restBottom, *accentFocus, *accentRest, *ink, *mutedInk, *buttonInk;
@property BOOL light;
@property Ambient ambient;
@end
@implementation Theme
- (NSString *)name { return T(self.zh, self.en); }
- (NSColor *)accent:(BOOL)rest { return rest ? self.accentRest : self.accentFocus; }
- (NSArray<NSColor *> *)gradient:(BOOL)rest { return rest ? @[self.restTop, self.restBottom] : @[self.focusTop, self.focusBottom]; }
@end

static Theme *makeTheme(NSString *key, NSString *zh, NSString *en, unsigned ft, unsigned fb, unsigned rt, unsigned rb, unsigned af, unsigned ar,
                        unsigned ink, unsigned muted, unsigned button, BOOL light, Ambient ambient) {
    Theme *t = [Theme new]; t.key = key; t.zh = zh; t.en = en;
    t.focusTop = hex(ft, 1); t.focusBottom = hex(fb, 1); t.restTop = hex(rt, 1); t.restBottom = hex(rb, 1);
    t.accentFocus = hex(af, 1); t.accentRest = hex(ar, 1); t.ink = hex(ink, 1); t.mutedInk = hex(muted, 1); t.buttonInk = hex(button, 1);
    t.light = light; t.ambient = ambient; return t;
}
static NSArray<Theme *> *allThemes(void) {
    static NSArray *themes; static dispatch_once_t once;
    dispatch_once(&once, ^{
        themes = @[
            makeTheme(@"aurora", @"极光", @"Aurora", 0x142657, 0x30306E, 0x0A2846, 0x0B4A48, 0x9EC4FF, 0x54EDC7, 0xFFFFFF, 0xE4ECFC, 0x0F1F3D, NO, AmbientDrift),
            makeTheme(@"frost", @"霜玻璃", @"Frost", 0xF5F8FF, 0xDCE4F8, 0xF3FBF8, 0xD5EEE7, 0x3558E8, 0x0B8A72, 0x141B33, 0x3F4864, 0xFFFFFF, YES, AmbientFrost),
            makeTheme(@"rain", @"细雨", @"Drizzle", 0x1B2635, 0x2C3C50, 0x172D2C, 0x24504A, 0x9CC3EA, 0x82D9C6, 0xFFFFFF, 0xE2EAF2, 0x0F1F3D, NO, AmbientRain),
            makeTheme(@"water", @"静水", @"Still Water", 0x0A2F40, 0x125468, 0x0B3A34, 0x146A59, 0x86E3F2, 0x9FF2CB, 0xFFFFFF, 0xE0F3F7, 0x0B2A33, NO, AmbientRipple),
            makeTheme(@"dusk", @"暮光", @"Dusk", 0x351C49, 0x7C3858, 0x22315A, 0x3A6878, 0xFFC793, 0x93E6D3, 0xFFFFFF, 0xF6E6EE, 0x3A1C2C, NO, AmbientDrift),
            makeTheme(@"graphite", @"石墨", @"Graphite", 0x19191D, 0x2A2A30, 0x161E1C, 0x22302B, 0xF2F2F7, 0xA8E9CE, 0xFFFFFF, 0xE6E6EB, 0x16161A, NO, AmbientNone),
        ];
    });
    return themes;
}
static Theme *themeNamed(NSString *key) {
    for (Theme *t in allThemes()) if ([t.key isEqualToString:key]) return t;
    return allThemes().firstObject;
}

// Completion sounds: curated macOS system sounds (always installed, no extra files) and None.
static NSArray<NSArray<NSString *> *> *allSounds(void) {
    return @[@[@"none", @"无", @"None"], @[@"Glass", @"玻璃", @"Glass"], @[@"Hero", @"凯旋", @"Hero"], @[@"Purr", @"轻鸣", @"Purr"],
             @[@"Ping", @"清脆", @"Ping"], @[@"Submarine", @"深海", @"Submarine"], @[@"Tink", @"叮", @"Tink"], @[@"Blow", @"微风", @"Blow"]];
}
static NSString *validSound(NSString *name) {
    for (NSArray *s in allSounds()) if ([s[0] isEqualToString:name]) return name;
    return @"Glass";
}

#pragma mark - Icons

// One icon language: SF Symbols, one weight, sizes from a small scale, template-tinted.
static NSImage *symbol(NSString *name, CGFloat size, NSString *label) {
    NSImage *base = [NSImage imageWithSystemSymbolName:name accessibilityDescription:label];
    NSImage *img = [base imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightSemibold scale:NSImageSymbolScaleMedium]];
    img.template = YES; return img;
}
static NSImage *phaseSymbol(BOOL rest, CGFloat size) {
    return symbol(rest ? @"cup.and.saucer.fill" : @"hourglass", size, rest ? T(@"休息", @"Break") : T(@"专注", @"Focus"));
}
static NSImage *menuImage(BOOL rest) { return phaseSymbol(rest, 14); }
static NSImage *tinted(NSImage *image, NSColor *color) {
    if (!image) return nil;
    return [NSImage imageWithSize:image.size flipped:NO drawingHandler:^BOOL(NSRect r) {
        [image drawInRect:r]; [color setFill]; NSRectFillUsingOperation(r, NSCompositingOperationSourceIn); return YES; }];
}

// App icon (v3.1): squircle body with the macOS icon margin, a bright sky-blue to violet gradient, a soft
// highlight, a white progress ring and the same SF Symbols hourglass the app uses everywhere else.
static void drawIcon(NSRect rect) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t = [NSAffineTransform transform]; [t translateXBy:rect.origin.x yBy:rect.origin.y]; [t scaleXBy:rect.size.width / 1024 yBy:rect.size.height / 1024]; [t concat];
    NSRect body = NSMakeRect(100, 100, 824, 824);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:body xRadius:186 yRadius:186];
    NSShadow *shadow = [NSShadow new]; shadow.shadowColor = rgb(0, 0, 0, .28); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSMakeSize(0, -10);
    [NSGraphicsContext saveGraphicsState]; [shadow set]; [rgb(.36, .52, 1, 1) setFill]; [shape fill]; [NSGraphicsContext restoreGraphicsState];
    NSGradient *g = [[NSGradient alloc] initWithColors:@[rgb(.36, .78, 1, 1), rgb(.38, .55, 1, 1), rgb(.52, .38, 1, 1)]];
    [g drawInBezierPath:shape angle:-60];
    [NSGraphicsContext saveGraphicsState]; [shape addClip];
    NSGradient *gloss = [[NSGradient alloc] initWithStartingColor:rgb(1, 1, 1, .38) endingColor:rgb(1, 1, 1, 0)];
    [gloss drawFromCenter:NSMakePoint(330, 860) radius:0 toCenter:NSMakePoint(330, 860) radius:620 options:0];
    [NSGraphicsContext restoreGraphicsState];
    NSPoint c = NSMakePoint(512, 512); CGFloat r = 268;
    NSBezierPath *track = [NSBezierPath bezierPath]; [track appendBezierPathWithArcWithCenter:c radius:r startAngle:0 endAngle:360];
    track.lineWidth = 44; [rgb(1, 1, 1, .26) setStroke]; [track stroke];
    NSShadow *soft = [NSShadow new]; soft.shadowColor = rgb(.16, .12, .48, .30); soft.shadowBlurRadius = 18; soft.shadowOffset = NSMakeSize(0, -8);
    [NSGraphicsContext saveGraphicsState]; [soft set];
    NSBezierPath *arc = [NSBezierPath bezierPath]; [arc appendBezierPathWithArcWithCenter:c radius:r startAngle:90 endAngle:90 - 270 clockwise:YES];
    arc.lineWidth = 44; arc.lineCapStyle = NSLineCapStyleRound; [NSColor.whiteColor setStroke]; [arc stroke];
    NSImage *glass = [[NSImage imageWithSystemSymbolName:@"hourglass" accessibilityDescription:nil]
                      imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:250 weight:NSFontWeightSemibold]];
    if (glass) { NSSize gs = glass.size; [tinted(glass, NSColor.whiteColor) drawInRect:NSMakeRect(c.x - gs.width / 2, c.y - gs.height / 2, gs.width, gs.height)]; }
    [NSGraphicsContext restoreGraphicsState];
    NSPoint end = NSMakePoint(c.x - r, c.y);   // Mint dot at the end of the ring: the break accent.
    [rgb(.40, .96, .82, 1) setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(end.x - 30, end.y - 30, 60, 60)] fill];
    [NSGraphicsContext restoreGraphicsState];
}
static void exportIcons(NSString *directory) {
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *names = @[@"icon_16x16.png", @"icon_16x16@2x.png", @"icon_32x32.png", @"icon_32x32@2x.png", @"icon_128x128.png", @"icon_128x128@2x.png", @"icon_256x256.png", @"icon_256x256@2x.png", @"icon_512x512.png", @"icon_512x512@2x.png"];
    NSArray *sizes = @[@16, @32, @32, @64, @128, @256, @256, @512, @512, @1024];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSInteger size = [sizes[i] integerValue];
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:size pixelsHigh:size bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        drawIcon(NSMakeRect(0, 0, size, size)); [NSGraphicsContext restoreGraphicsState];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[directory stringByAppendingPathComponent:names[i]] atomically:YES];
    }
}

#pragma mark - Card views

static const CGFloat kCardW = 300, kCardH = 350, kCompactW = 280, kCompactH = 144;
// The card window is larger than the card by this margin on each side. The card draws its own soft shadow there:
// the system window shadow adds a dark outline around a borderless translucent window.
static const CGFloat kPad = 24;
// The card view is flipped: frames are written from the top, so they stay put while the window resizes.
static NSRect TOP(CGFloat x, CGFloat top, CGFloat w, CGFloat h) { return NSMakeRect(x, top, w, h); }

@interface CardWindow : NSWindow @end
@implementation CardWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
// Space starts or pauses the timer unless a focused button wants the key itself.
- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl);
    if (!mods && [event.charactersIgnoringModifiers isEqualToString:@" "]) { [NSApp sendAction:NSSelectorFromString(@"toggle:") to:self.delegate from:self]; return; }
    [super keyDown:event];
}
// A borderless window has no close button; Command-W hides the card and keeps the timer running.
- (void)performClose:(id)sender { [NSApp sendAction:NSSelectorFromString(@"hideCard:") to:self.delegate from:self]; }
// A borderless window disables Close (Command-W) by default; the card supports it.
- (BOOL)validateMenuItem:(NSMenuItem *)item { return item.action == @selector(performClose:) ? YES : [super validateMenuItem:item]; }
@end

@interface PassiveLabel : NSTextField
@property (copy) NSString *(^axLabel)(void);   // computed when VoiceOver asks, not on every tick
@end
@implementation PassiveLabel
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (NSString *)accessibilityLabel { return self.axLabel ? self.axLabel() : [super accessibilityLabel]; }
@end
@interface PassiveEffectView : NSVisualEffectView @end
@implementation PassiveEffectView
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

// The card background: a theme gradient in a Core Animation layer, a soft glass highlight and an effects layer
// for the theme's ambient motion. All motion runs in the render server (no per-frame work in the app).
@interface ThemeSurface : NSView
@property Theme *theme;
@property BOOL rest, motion;
@property double opacity, radius;
@property CAGradientLayer *gradient, *sheen, *glow;
@property CALayer *fx;
@property NSTimer *spawner;
@property NSInteger liveDrops;
@end
@implementation ThemeSurface
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES; self.layer.masksToBounds = YES;
        self.gradient = [CAGradientLayer layer]; self.sheen = [CAGradientLayer layer]; self.fx = [CALayer layer];
        self.glow = [CAGradientLayer layer]; self.glow.type = kCAGradientLayerRadial; self.glow.opacity = 0;
        self.glow.startPoint = CGPointMake(.5, .5); self.glow.endPoint = CGPointMake(1, 1);
        self.fx.masksToBounds = YES;
        for (CALayer *l in @[self.gradient, self.glow, self.sheen, self.fx]) [self.layer addSublayer:l];
        self.radius = 24; self.opacity = .45; self.theme = allThemes().firstObject;
        [self syncLayers];
    }
    return self;
}
- (NSView *)hitTest:(NSPoint)point { return nil; }
// Layer frames follow the view on every size change (the view is sized by autoresizing, so -layout alone is not enough).
- (void)syncLayers {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (CALayer *l in @[self.gradient, self.sheen, self.fx]) l.frame = self.bounds;
    CGFloat d = MAX(self.bounds.size.width, self.bounds.size.height) * 1.1;
    self.glow.bounds = CGRectMake(0, 0, d, d);
    self.glow.position = CGPointMake(self.bounds.size.width * .12, self.bounds.size.height * .92);   // upper-left (unflipped)
    self.layer.cornerRadius = self.radius;
    [CATransaction commit];
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self syncLayers]; }
- (void)layout { [super layout]; [self syncLayers]; }
- (void)apply {
    NSWorkspace *ws = NSWorkspace.sharedWorkspace;
    // The lowest setting keeps small text at about 4.4:1 or better (contrast checks TH-01, CC-02).
    CGFloat alpha = ws.accessibilityDisplayShouldReduceTransparency ? .97 : .74 + self.opacity * .26;
    NSArray<NSColor *> *cs = [self.theme gradient:self.rest];
    [CATransaction begin]; [CATransaction setAnimationDuration:.45];
    self.gradient.colors = @[(id)[cs[0] colorWithAlphaComponent:alpha].CGColor, (id)[cs[1] colorWithAlphaComponent:alpha].CGColor];
    if (![self.gradient animationForKey:@"drift"]) { self.gradient.startPoint = CGPointMake(0, 1); self.gradient.endPoint = CGPointMake(1, 0); }
    CGFloat sheen = self.theme.light ? .55 : .12;
    self.sheen.colors = @[(id)rgb(1, 1, 1, sheen).CGColor, (id)rgb(1, 1, 1, 0).CGColor];
    self.sheen.startPoint = CGPointMake(.5, 1); self.sheen.endPoint = CGPointMake(.5, .45);
    self.layer.borderWidth = ws.accessibilityDisplayShouldIncreaseContrast ? 2 : 0;   // Outline only with Increase Contrast.
    self.layer.borderColor = [self.theme.ink colorWithAlphaComponent:.6].CGColor;
    [CATransaction commit];
    [self updateMotion];
}
- (BOOL)motionAllowed { return self.motion && !reduceMotion() && self.window.visible && self.theme.ambient != AmbientNone; }
static CAMediaTimingFunction *easeInOut(void) { return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]; }
static double rnd(double lo, double hi) { return lo + (hi - lo) * arc4random_uniform(10001) / 10000.0; }
// Ambient motion. Principles: slow, sparse and physically plausible; nothing loops in an obvious way; nothing moves
// faster than the eye expects from light, glass or water. All motion runs in the render server.
- (void)updateMotion {
    BOOL on = [self motionAllowed];
    [self.spawner invalidate]; self.spawner = nil;
    if (!on) { [self.gradient removeAllAnimations]; [self.sheen removeAllAnimations]; [self.glow removeAllAnimations]; self.glow.opacity = 0;
               self.fx.sublayers = nil; self.liveDrops = 0; return; }
    // Light: a soft source in the upper-left corner, breathing very slowly (like daylight through a window).
    NSColor *accent = [self.theme accent:self.rest];
    self.glow.colors = @[(id)[accent colorWithAlphaComponent:self.theme.light ? .16 : .20].CGColor, (id)[accent colorWithAlphaComponent:0].CGColor];
    self.glow.opacity = 1;
    if (![self.glow animationForKey:@"breathe"]) {
        CABasicAnimation *b = [CABasicAnimation animationWithKeyPath:@"opacity"]; b.fromValue = @.45; b.toValue = @1; b.duration = 11; b.autoreverses = YES; b.repeatCount = HUGE_VALF;
        b.timingFunction = easeInOut(); b.beginTime = CACurrentMediaTime() - rnd(0, 11); [self.glow addAnimation:b forKey:@"breathe"];
    }
    // The gradient's light band shifts a little over a long period.
    if (![self.gradient animationForKey:@"drift"]) {
        CABasicAnimation *l = [CABasicAnimation animationWithKeyPath:@"locations"]; l.fromValue = @[@0, @1]; l.toValue = @[@-.18, @.82];
        CABasicAnimation *e = [CABasicAnimation animationWithKeyPath:@"endPoint"]; e.fromValue = [NSValue valueWithPoint:NSMakePoint(1, 0)]; e.toValue = [NSValue valueWithPoint:NSMakePoint(.88, 0)];
        CAAnimationGroup *g = [CAAnimationGroup animation]; g.animations = @[l, e]; g.duration = 23; g.autoreverses = YES; g.repeatCount = HUGE_VALF; g.timingFunction = easeInOut();
        [self.gradient addAnimation:g forKey:@"drift"];
    }
    Ambient amb = self.theme.ambient;
    if (amb == AmbientRain || amb == AmbientRipple || amb == AmbientFrost) [self scheduleSpawn:amb == AmbientRain ? rnd(.8, 1.6) : rnd(2, 4)];
}
- (void)scheduleSpawn:(double)delay {
    __weak ThemeSurface *weakSelf = self;
    self.spawner = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
        ThemeSurface *s = weakSelf; if (![s motionAllowed]) return;
        CGFloat w = s.bounds.size.width, h = s.bounds.size.height;
        switch (s.theme.ambient) {
            case AmbientRain:   // Drizzle on still water: small, frequent ripples, sometimes two close together.
                [s rippleAt:NSMakePoint(rnd(w * .1, w * .9), rnd(h * .1, h * .9)) strength:rnd(.45, .7) size:rnd(.45, .7)];
                if (arc4random_uniform(100) < 30) [s rippleAt:NSMakePoint(rnd(w * .1, w * .9), rnd(h * .1, h * .9)) strength:rnd(.35, .55) size:rnd(.35, .55)];
                [s scheduleSpawn:rnd(1.6, 3.4)]; break;
            case AmbientRipple: [s rippleAt:NSMakePoint(rnd(w * .15, w * .85), rnd(h * .15, h * .85)) strength:rnd(.6, .9)]; [s scheduleSpawn:rnd(7, 12)]; break;
            case AmbientFrost: [s glint]; [s scheduleSpawn:rnd(10, 16)]; break;
            default: break;
        }
    }];
    self.spawner.tolerance = .5;
}
// Water: two or three thin concentric rings that widen with an ease-out and thin away, the way a drop spreads on still water.
- (void)rippleAt:(NSPoint)p strength:(CGFloat)strength { [self rippleAt:p strength:strength size:1]; }
- (void)rippleAt:(NSPoint)p strength:(CGFloat)strength size:(CGFloat)size {
    if (reduceMotion() || !self.motion) return;
    NSInteger rings = size < .8 ? 2 : 2 + arc4random_uniform(2);
    for (NSInteger i = 0; i < rings; i++) {
        CAShapeLayer *ring = [CAShapeLayer layer]; CGFloat r = 46 * size;
        CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(-r, -r * .92, 2 * r, 2 * r * .92), NULL); ring.path = path; CGPathRelease(path);
        ring.fillColor = NSColor.clearColor.CGColor; ring.strokeColor = [self.theme.ink colorWithAlphaComponent:(.30 - i * .08) * strength].CGColor;
        ring.lineWidth = 1.4; ring.position = CGPointMake(p.x, p.y); ring.opacity = 0;   // p is in this (unflipped) view's coordinates.
        [self.fx addSublayer:ring];
        CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"]; scale.fromValue = @.06; scale.toValue = @(1.5 - i * .18);
        scale.timingFunction = [CAMediaTimingFunction functionWithControlPoints:.15 :.6 :.3 :1];
        CABasicAnimation *thin = [CABasicAnimation animationWithKeyPath:@"lineWidth"]; thin.fromValue = @2.2; thin.toValue = @.3;
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"]; fade.values = @[@0, @1, @.6, @0]; fade.keyTimes = @[@0, @.08, @.45, @1];
        CAAnimationGroup *g = [CAAnimationGroup animation]; g.animations = @[scale, thin, fade]; g.duration = (3.6 - i * .3) * (.6 + .4 * size);
        g.beginTime = CACurrentMediaTime() + i * .42; g.fillMode = kCAFillModeBoth; g.removedOnCompletion = NO;
        [CATransaction begin]; [CATransaction setCompletionBlock:^{ [ring removeFromSuperlayer]; }]; [ring addAnimation:g forKey:@"ripple"]; [CATransaction commit];
    }
}
// Frosted glass: now and then a broad, faint band of light passes diagonally across the glass.
- (void)glint {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, band = w * .55;
    CAGradientLayer *l = [CAGradientLayer layer];
    l.colors = @[(id)rgb(1, 1, 1, 0).CGColor, (id)rgb(1, 1, 1, self.theme.light ? .38 : .12).CGColor, (id)rgb(1, 1, 1, 0).CGColor];
    l.startPoint = CGPointMake(0, .5); l.endPoint = CGPointMake(1, .5);
    l.bounds = CGRectMake(0, 0, band, hypot(w, h) * 1.2); l.transform = CATransform3DMakeRotation(-M_PI / 7, 0, 0, 1);
    l.position = CGPointMake(-band, h / 2); l.opacity = 0; [self.fx addSublayer:l];
    CABasicAnimation *mv = [CABasicAnimation animationWithKeyPath:@"position.x"]; mv.fromValue = @(-band * .6); mv.toValue = @(w + band * .6);
    mv.timingFunction = easeInOut();
    CAKeyframeAnimation *op = [CAKeyframeAnimation animationWithKeyPath:@"opacity"]; op.values = @[@0, @1, @1, @0]; op.keyTimes = @[@0, @.2, @.8, @1];
    CAAnimationGroup *g = [CAAnimationGroup animation]; g.animations = @[mv, op]; g.duration = 3.4; g.removedOnCompletion = NO; g.fillMode = kCAFillModeForwards;
    [CATransaction begin]; [CATransaction setCompletionBlock:^{ [l removeFromSuperlayer]; }]; [l addAnimation:g forKey:@"glint"]; [CATransaction commit];
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self updateMotion]; }
- (void)drawRect:(NSRect)rect {   // Only for screenshots; on screen the layers draw.
    if (!gSnapshot) return;
    CGFloat alpha = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency ? .97 : .74 + self.opacity * .26;
    NSArray<NSColor *> *cs = [self.theme gradient:self.rest];
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:self.radius yRadius:self.radius];
    [[[NSGradient alloc] initWithStartingColor:[cs[0] colorWithAlphaComponent:alpha] endingColor:[cs[1] colorWithAlphaComponent:alpha]] drawInBezierPath:p angle:-45];
    CGFloat sheen = self.theme.light ? .55 : .12, h = self.bounds.size.height;
    [NSGraphicsContext saveGraphicsState]; [p addClip];
    [[[NSGradient alloc] initWithStartingColor:rgb(1, 1, 1, sheen) endingColor:rgb(1, 1, 1, 0)] drawInRect:NSMakeRect(0, h * .45, self.bounds.size.width, h * .55) angle:-90];
    [NSGraphicsContext restoreGraphicsState];
}
@end

@interface RingView : NSView
@property double progress;
@property BOOL rest, dimmed;
@property Theme *theme;
@property CAShapeLayer *track, *arc;
@property NSString *styleKey;   // what the path and colors were built for
@end
// The progress ring is two Core Animation shape layers: a new second only changes strokeEnd, which the render server
// draws (no per-second AppKit drawing; performance test PF-01). drawRect is used only for screenshots.
@implementation RingView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES; self.track = [CAShapeLayer layer]; self.arc = [CAShapeLayer layer];
        for (CAShapeLayer *l in @[self.track, self.arc]) { l.fillColor = NSColor.clearColor.CGColor; l.lineCap = kCALineCapRound; [self.layer addSublayer:l]; }
    }
    return self;
}
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityProgressIndicatorRole; }
- (NSString *)accessibilityLabel { return T(@"阶段进度", @"Phase progress"); }
- (id)accessibilityValue { return [NSString stringWithFormat:@"%ld%%", (long)lround(MAX(0, MIN(1, self.progress)) * 100)]; }
- (CGFloat)lineWidth { return MIN(self.bounds.size.width, self.bounds.size.height) > 150 ? 6 : 4; }
- (void)syncLayers {
    if (!self.track) return;   // AppKit calls setNeedsDisplay during -initWithFrame.
    Theme *th = self.theme ?: allThemes().firstObject;
    CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height), line = [self lineWidth], radius = d / 2 - line;
    CGPoint c = CGPointMake(NSMidX(self.bounds), NSMidY(self.bounds));
    double p = MAX(0, MIN(1, self.progress));
    NSString *key = [NSString stringWithFormat:@"%@|%d|%d|%d|%@", th.key, self.rest, self.dimmed, gSnapshot, NSStringFromSize(self.bounds.size)];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    if ([key isEqualToString:self.styleKey]) {   // A new second: only the arc length changes.
        if (self.arc.strokeEnd != p) self.arc.strokeEnd = p;
        BOOL hide = p <= 0 || gSnapshot; if (self.arc.hidden != hide) self.arc.hidden = hide;
        [CATransaction commit]; return;
    }
    self.styleKey = key;
    CGMutablePathRef path = CGPathCreateMutable(); CGPathAddArc(path, NULL, c.x, c.y, radius, M_PI_2, M_PI_2 - 2 * M_PI, true);   // from 12 o'clock, clockwise
    for (CAShapeLayer *l in @[self.track, self.arc]) { l.frame = self.bounds; l.path = path; l.lineWidth = line; }
    CGPathRelease(path);
    self.track.strokeColor = [th.ink colorWithAlphaComponent:th.light ? .14 : .10].CGColor;
    self.arc.strokeColor = [[th accent:self.rest] colorWithAlphaComponent:self.dimmed ? .45 : 1].CGColor;
    self.arc.strokeEnd = p; self.arc.hidden = p <= 0 || gSnapshot;
    self.track.hidden = gSnapshot;
    [CATransaction commit];
}
- (void)setNeedsDisplay:(BOOL)flag { [self syncLayers]; if (gSnapshot) [super setNeedsDisplay:flag]; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self syncLayers]; }
- (void)drawRect:(NSRect)rect {   // Screenshots only.
    if (!gSnapshot) return;
    Theme *th = self.theme ?: allThemes().firstObject;
    CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height), line = [self lineWidth], radius = d / 2 - line;
    NSPoint c = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
    NSBezierPath *track = [NSBezierPath bezierPath]; [track appendBezierPathWithArcWithCenter:c radius:radius startAngle:0 endAngle:360];
    track.lineWidth = line; [[th.ink colorWithAlphaComponent:th.light ? .14 : .10] setStroke]; [track stroke];
    double p = MAX(0, MIN(1, self.progress));
    if (p <= 0) return;
    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:c radius:radius startAngle:90 endAngle:90 - 360 * p clockwise:YES];
    arc.lineWidth = line; arc.lineCapStyle = NSLineCapStyleRound;
    [[[th accent:self.rest] colorWithAlphaComponent:self.dimmed ? .45 : 1] setStroke]; [arc stroke];
}
@end

// The card's content view. The background moves the window; a double-click on the time while paused opens
// the duration settings (the handler decides); a click on the background can make a ripple.
@interface CardView : NSView
@property (copy) BOOL (^onDoubleClick)(NSPoint p);
@property (copy) void (^onClick)(NSPoint p);
@property NSRect editableRect;
@end
@implementation CardView
- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (event.clickCount == 2 && self.onDoubleClick && self.onDoubleClick(p)) return;
    if (self.onClick) self.onClick(p);
    [self.window performWindowDragWithEvent:event];
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)resetCursorRects { if (!NSIsEmptyRect(self.editableRect)) [self addCursorRect:self.editableRect cursor:NSCursor.pointingHandCursor]; }
@end

// The card's buttons, drawn in the theme's colors with hover, press, focus and disabled states.
@interface GlowButton : NSButton
@property BOOL primary, rest, hovered, quiet, round;   // quiet: no fill until hover; round: a circle
@property Theme *theme;
@property NSTrackingArea *tracking;
@end
@implementation GlowButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingActiveAlways | NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)event { self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { self.hovered = NO; self.needsDisplay = YES; }
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; self.needsDisplay = YES; }
// Custom drawing hides a button from accessibility by default (defect D-03): expose it as a real button.
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (BOOL)isAccessibilityEnabled { return self.enabled; }
- (BOOL)accessibilityPerformPress { if (!self.enabled) return NO; [self performClick:nil]; return YES; }
- (void)drawRect:(NSRect)rect {
    Theme *th = self.theme ?: allThemes().firstObject;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx); CGContextSetAlpha(ctx, self.enabled ? 1 : .32); CGContextBeginTransparencyLayer(ctx, NULL);
    CGFloat radius = self.round || self.quiet ? self.bounds.size.height / 2 - 1 : MIN(14, self.bounds.size.height / 2 - 1);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:radius yRadius:radius];
    BOOL live = self.enabled;
    if (self.primary) {
        NSColor *a = [th accent:self.rest];
        NSGradient *g = [[NSGradient alloc] initWithStartingColor:mix(a, NSColor.whiteColor, th.light ? .12 : .30) endingColor:a];
        [g drawInBezierPath:shape angle:0];
    } else if (!self.quiet || (live && (self.hovered || self.highlighted))) {
        [[th.ink colorWithAlphaComponent:live && self.hovered ? (th.light ? .12 : .16) : (th.light ? .07 : .08)] setFill]; [shape fill];
    }
    if (live && self.highlighted) { [rgb(0, 0, 0, .16) setFill]; [shape fill]; }
    else if (live && self.hovered && self.primary) { [rgb(1, 1, 1, .14) setFill]; [shape fill]; }
    NSColor *ink = self.primary ? th.buttonInk : th.ink;
    if (self.image) {
        NSSize is = self.image.size; CGFloat k = MIN(1, (self.bounds.size.height - 8) / MAX(1, MAX(is.width, is.height)));
        CGFloat iw = round(is.width * k), ih = round(is.height * k);
        NSRect area = NSMakeRect(floor((self.bounds.size.width - iw) / 2), floor((self.bounds.size.height - ih) / 2), iw, ih);
        [tinted(self.image, ink) drawInRect:area fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    } else {
        NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: ink};
        NSSize size = [self.title sizeWithAttributes:attrs];
        [self.title drawAtPoint:NSMakePoint(round((self.bounds.size.width - size.width) / 2), round((self.bounds.size.height - size.height) / 2)) withAttributes:attrs];
    }
    if (self.window.firstResponder == self && self.window.isKeyWindow) {
        NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1.5, 1.5) xRadius:radius yRadius:radius];
        [NSColor.keyboardFocusIndicatorColor setStroke]; ring.lineWidth = 2.5; [ring stroke];
    }
    CGContextEndTransparencyLayer(ctx); CGContextRestoreGState(ctx);
}
@end

#pragma mark - Completion overlay

// A full-screen, frosted-glass prompt shown when a phase ends. It covers every screen; the prompt itself is on the
// card's screen. Nothing continues until the user chooses: Return = the primary action, Escape = Not Now.
@interface OverlayWindow : NSWindow
@property (copy) void (^onPrimary)(void);
@property (copy) void (^onSecondary)(void);
@end
@implementation OverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)keyDown:(NSEvent *)event {
    NSString *c = event.charactersIgnoringModifiers;
    if (([c isEqualToString:@"\r"] || [c isEqualToString:@"\x03"]) && self.onPrimary) { self.onPrimary(); return; }
    if ((event.keyCode == 53 || [c isEqualToString:@"\e"]) && self.onSecondary) { self.onSecondary(); return; }
    [super keyDown:event];
}
- (void)cancelOperation:(id)sender { if (self.onSecondary) self.onSecondary(); }
// A click anywhere outside the two buttons means "Not Now" (the buttons take their own clicks first).
- (void)mouseDown:(NSEvent *)event { if (self.onSecondary) self.onSecondary(); }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
@end

// A rounded plate or disc drawn with AppKit (so that screenshots capture it too).
@interface Plate : NSView
@property NSColor *fill, *stroke;
@property CGFloat radius;
@end
@implementation Plate
- (NSView *)hitTest:(NSPoint)p { NSView *v = [super hitTest:p]; return v == self ? nil : v; }
- (void)drawRect:(NSRect)rect {
    CGFloat r = MIN(self.radius, self.bounds.size.height / 2);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, .5, .5) xRadius:r yRadius:r];
    if (self.fill) { [self.fill setFill]; [p fill]; }
    if (self.stroke) { p.lineWidth = 1; [self.stroke setStroke]; [p stroke]; }
}
@end

// The prompt's buttons: a calm, solid pill (primary) or a text button (secondary). A plain control, not an NSButton,
// so that AppKit adds no default-button bezel, pulse or focus rectangle on top of the drawing.
@interface PromptButton : NSControl
@property NSString *title;
@property NSColor *fill, *ink;
@property BOOL primary, hovered, pressed;
@property NSTrackingArea *tracking;
@end
@implementation PromptButton
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel { return self.title; }
- (BOOL)accessibilityPerformPress { [self sendAction:self.action to:self.target]; return YES; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingActiveAlways | NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)e { self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)e { self.hovered = NO; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)event {   // Press feedback; the action runs on release inside the button.
    self.pressed = YES; self.needsDisplay = YES;
    while (YES) {
        NSEvent *e = [self.window nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        BOOL in = NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], self.bounds);
        if (e.type == NSEventTypeLeftMouseUp) { self.pressed = NO; self.needsDisplay = YES; if (in) [self sendAction:self.action to:self.target]; return; }
        if (in != self.pressed) { self.pressed = in; self.needsDisplay = YES; }
    }
}
- (void)drawRect:(NSRect)rect {
    NSRect b = NSInsetRect(self.bounds, 1, 1);
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:b xRadius:b.size.height / 2 yRadius:b.size.height / 2];
    if (self.primary) {
        NSColor *f = self.pressed ? mix(self.fill, NSColor.blackColor, .12) : self.hovered ? mix(self.fill, NSColor.whiteColor, .10) : self.fill;
        [f setFill]; [pill fill];
    } else if (self.hovered || self.pressed) {
        [[self.ink colorWithAlphaComponent:self.pressed ? .14 : .08] setFill]; [pill fill];
    }
    NSFont *font = [NSFont systemFontOfSize:self.primary ? 15 : 14 weight:self.primary ? NSFontWeightSemibold : NSFontWeightMedium];
    NSColor *ink = self.primary ? self.ink : [self.ink colorWithAlphaComponent:.85];
    NSDictionary *a = @{NSFontAttributeName: font, NSForegroundColorAttributeName: ink};
    NSSize ts = [self.title sizeWithAttributes:a];
    [self.title drawAtPoint:NSMakePoint(round((self.bounds.size.width - ts.width) / 2), round((self.bounds.size.height - ts.height) / 2)) withAttributes:a];
}
@end

// The overlay's backdrop: takes the first click (even on a second display) so that one click anywhere dismisses.
@interface OverlayRoot : NSView @end
@implementation OverlayRoot
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
@end

@interface CompletionOverlay : NSObject
@property NSMutableArray<OverlayWindow *> *windows;
@property BOOL visible, headless;
@property BOOL passThrough;   // Live UI test only: real clicks of the person at the Mac go through to their apps.
@property NSString *title, *subtitle, *primaryTitle, *secondaryTitle;
@property PromptButton *primaryButton, *secondaryButton;
@property NSView *promptCard;
@property (copy) void (^onPrimary)(void);
@property (copy) void (^onSecondary)(void);
@end

@implementation CompletionOverlay
- (NSTextField *)text:(NSString *)s size:(CGFloat)size weight:(NSFontWeight)w color:(NSColor *)c {
    NSTextField *l = [NSTextField wrappingLabelWithString:s]; l.font = [NSFont systemFontOfSize:size weight:w]; l.textColor = c;
    l.alignment = NSTextAlignmentCenter; l.selectable = NO; return l;
}
- (NSView *)backdropWithTheme:(Theme *)th rest:(BOOL)rest frame:(NSRect)frame {
    NSView *root = [[OverlayRoot alloc] initWithFrame:frame]; root.wantsLayer = YES;
    NSVisualEffectView *blur = [[PassiveEffectView alloc] initWithFrame:root.bounds];
    blur.material = NSVisualEffectMaterialFullScreenUI; blur.blendingMode = NSVisualEffectBlendingModeBehindWindow; blur.state = NSVisualEffectStateActive;
    blur.appearance = [NSAppearance appearanceNamed:th.light ? NSAppearanceNameVibrantLight : NSAppearanceNameVibrantDark];
    blur.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [root addSubview:blur];
    ThemeSurface *tint = [[ThemeSurface alloc] initWithFrame:root.bounds]; tint.theme = th; tint.rest = rest; tint.radius = 0;
    tint.opacity = th.light ? -.9 : -.6;   // .74 + opacity * .26 → about 0.51 (light) or 0.58 (dark): the desktop stays faintly visible.
    tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [root addSubview:tint]; [tint apply];
    return root;
}
- (void)showTheme:(Theme *)th nextRest:(BOOL)nextRest title:(NSString *)title subtitle:(NSString *)subtitle primary:(NSString *)primary
        secondary:(NSString *)secondary hint:(NSString *)hint screen:(NSScreen *)mainScreen animate:(BOOL)animate {
    [self dismissAnimated:NO];
    self.title = title; self.subtitle = subtitle; self.primaryTitle = primary; self.secondaryTitle = secondary; self.visible = YES;
    if (self.headless) return;
    self.windows = [NSMutableArray array];
    NSScreen *home = mainScreen ?: NSScreen.mainScreen;
    for (NSScreen *screen in NSScreen.screens) {
        OverlayWindow *w = [[OverlayWindow alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        w.opaque = NO; w.backgroundColor = NSColor.clearColor; w.hasShadow = NO; w.releasedWhenClosed = NO; w.ignoresMouseEvents = self.passThrough;
        w.level = NSStatusWindowLevel + 2;   // Above the menu bar and the Dock, below system alerts.
        w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
        w.appearance = [NSAppearance appearanceNamed:th.light ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
        __weak CompletionOverlay *weakSelf = self;
        w.onPrimary = ^{ if (weakSelf.onPrimary) weakSelf.onPrimary(); };
        w.onSecondary = ^{ if (weakSelf.onSecondary) weakSelf.onSecondary(); };
        NSView *root = [self backdropWithTheme:th rest:nextRest frame:NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height)];
        w.contentView = root;
        if (screen == home) [self buildPromptIn:root theme:th rest:nextRest hint:hint];
        [w setAccessibilityLabel:title];
        // In the live UI test the prompt is nearly invisible and lets real clicks through, so it never gets in the way
        // of the person using the Mac; the test still drives it with synthetic events and captures it.
        CGFloat shown = self.passThrough ? .02 : 1;
        w.alphaValue = animate ? 0 : shown;
        [self.windows addObject:w];
        [w orderFrontRegardless];
        if (screen == home) { [w makeKeyAndOrderFront:nil]; [w makeFirstResponder:nil]; }
    }
    if (@available(macOS 14.0, *)) [NSApp activate]; else [NSApp activateIgnoringOtherApps:YES];
    if (animate) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = .35; for (NSWindow *w in self.windows) w.animator.alphaValue = self.passThrough ? .02 : 1; }];
        CABasicAnimation *s = [CABasicAnimation animationWithKeyPath:@"transform.scale"]; s.fromValue = @.96; s.toValue = @1; s.duration = .45;
        s.timingFunction = [CAMediaTimingFunction functionWithControlPoints:.2 :.9 :.25 :1];
        [self.promptCard.layer addAnimation:s forKey:@"in"];
    }
    NSAccessibilityPostNotificationWithUserInfo(self.promptCard ?: NSApp, NSAccessibilityAnnouncementRequestedNotification,
                                                @{NSAccessibilityAnnouncementKey: [NSString stringWithFormat:@"%@. %@", title, subtitle], NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh)});
}
- (void)buildPromptIn:(NSView *)root theme:(Theme *)th rest:(BOOL)rest hint:(NSString *)hint {
    CGFloat W = 480, H = 340;
    Plate *card = [[Plate alloc] initWithFrame:NSMakeRect(round((root.bounds.size.width - W) / 2), round((root.bounds.size.height - H) / 2), W, H)];
    card.wantsLayer = YES; card.layer.cornerRadius = 28; card.layer.masksToBounds = YES; card.radius = 28;
    card.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    // Center the scale-in animation on the card.
    card.layer.anchorPoint = CGPointMake(.5, .5); card.layer.position = CGPointMake(NSMidX(card.frame), NSMidY(card.frame));
    // A nearly opaque panel in the theme's colors, so the text reads well over any desktop.
    ThemeSurface *panel = [[ThemeSurface alloc] initWithFrame:card.bounds]; panel.theme = th; panel.rest = rest; panel.radius = 28; panel.opacity = .75;
    panel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [card addSubview:panel]; [panel apply];
    NSColor *accent = [th accent:rest];
    Plate *badge = [[Plate alloc] initWithFrame:NSMakeRect(0, 0, 76, 76)]; badge.radius = 38; badge.fill = [accent colorWithAlphaComponent:.20];
    NSImageView *icon = [NSImageView imageViewWithImage:phaseSymbol(rest, 32)]; icon.contentTintColor = accent; icon.frame = NSMakeRect(18, 18, 40, 40); [badge addSubview:icon];
    [badge.widthAnchor constraintEqualToConstant:76].active = YES; [badge.heightAnchor constraintEqualToConstant:76].active = YES;
    NSTextField *title = [self text:self.title size:30 weight:NSFontWeightSemibold color:th.ink];
    NSTextField *sub = [self text:self.subtitle size:15 weight:NSFontWeightRegular color:th.mutedInk]; sub.preferredMaxLayoutWidth = 400;
    PromptButton *primary = [[PromptButton alloc] initWithFrame:NSMakeRect(0, 0, 260, 48)]; primary.primary = YES;
    primary.fill = accent; primary.ink = th.buttonInk; primary.title = self.primaryTitle; primary.target = self; primary.action = @selector(primaryPressed:);
    [primary.widthAnchor constraintEqualToConstant:260].active = YES; [primary.heightAnchor constraintEqualToConstant:48].active = YES;
    PromptButton *secondary = [[PromptButton alloc] initWithFrame:NSMakeRect(0, 0, 140, 36)]; secondary.ink = th.ink;
    secondary.title = self.secondaryTitle; secondary.target = self; secondary.action = @selector(secondaryPressed:);
    [secondary.widthAnchor constraintEqualToConstant:140].active = YES; [secondary.heightAnchor constraintEqualToConstant:36].active = YES;
    NSTextField *hintLabel = [self text:hint size:11 weight:NSFontWeightRegular color:[th.mutedInk colorWithAlphaComponent:.75]];
    NSStackView *stack = [NSStackView stackViewWithViews:@[badge, title, sub, primary, secondary, hintLabel]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.alignment = NSLayoutAttributeCenterX; stack.spacing = 12;
    [stack setCustomSpacing:20 afterView:badge]; [stack setCustomSpacing:8 afterView:title]; [stack setCustomSpacing:26 afterView:sub];
    [stack setCustomSpacing:8 afterView:primary]; [stack setCustomSpacing:8 afterView:secondary];
    stack.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.centerXAnchor constraintEqualToAnchor:card.centerXAnchor], [stack.centerYAnchor constraintEqualToAnchor:card.centerYAnchor]]];
    [root addSubview:card];
    self.promptCard = card; self.primaryButton = primary; self.secondaryButton = secondary;
    if (!reduceMotion()) {   // One soft ring from the badge: the only motion on this screen.
        CAShapeLayer *ring = [CAShapeLayer layer]; CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(-40, -40, 80, 80), NULL); ring.path = path; CGPathRelease(path);
        ring.fillColor = NSColor.clearColor.CGColor; ring.strokeColor = [accent colorWithAlphaComponent:.5].CGColor; ring.lineWidth = 1.5; ring.opacity = 0;
        [card layoutSubtreeIfNeeded];
        NSRect b = [card convertRect:badge.bounds fromView:badge]; ring.position = CGPointMake(NSMidX(b), NSMidY(b)); [card.layer addSublayer:ring];
        CABasicAnimation *sc = [CABasicAnimation animationWithKeyPath:@"transform.scale"]; sc.fromValue = @1; sc.toValue = @2.2;
        CAKeyframeAnimation *op = [CAKeyframeAnimation animationWithKeyPath:@"opacity"]; op.values = @[@0, @.9, @0]; op.keyTimes = @[@0, @.2, @1];
        CAAnimationGroup *g = [CAAnimationGroup animation]; g.animations = @[sc, op]; g.duration = 2.4; g.beginTime = CACurrentMediaTime() + .3; g.repeatCount = 2;
        [ring addAnimation:g forKey:@"pulse"];
    }
}
- (void)primaryPressed:(id)sender { if (self.onPrimary) self.onPrimary(); }
- (void)secondaryPressed:(id)sender { if (self.onSecondary) self.onSecondary(); }
- (void)dismissAnimated:(BOOL)animate {
    NSArray *ws = self.windows; self.windows = nil; self.visible = NO; self.primaryButton = nil; self.secondaryButton = nil; self.promptCard = nil;
    if (!ws.count) return;
    if (!animate || reduceMotion()) { for (NSWindow *w in ws) [w orderOut:nil]; return; }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = .22; for (NSWindow *w in ws) w.animator.alphaValue = 0; }
                        completionHandler:^{ for (NSWindow *w in ws) [w orderOut:nil]; }];
}
@end

#pragma mark - Settings building blocks

// A rounded group of rows, as in System Settings.
@interface GroupBox : NSView @end
@implementation GroupBox
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, .5, .5) xRadius:10 yRadius:10];
    [[NSColor.labelColor colorWithAlphaComponent:.05] setFill]; [p fill];   // A soft filled group; no outline.
}
@end

// A hairline between two rows of a group.
@interface Hairline : NSView @end
@implementation Hairline
- (void)drawRect:(NSRect)rect { [[NSColor.labelColor colorWithAlphaComponent:.08] setFill]; NSRectFillUsingOperation(NSMakeRect(0, 0, self.bounds.size.width, 1), NSCompositingOperationSourceOver); }
@end

// One pane button in the Settings tab strip: SF symbol over a short label; the selected pane is tinted.
@interface PaneButton : NSButton
@property BOOL selectedPane, hovered;
@property NSTrackingArea *tracking;
@property NSString *symbolName;
@end
@implementation PaneButton
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingActiveAlways | NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)e { self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)e { self.hovered = NO; self.needsDisplay = YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityRadioButtonRole; }
- (id)accessibilityValue { return @(self.selectedPane); }
- (void)drawRect:(NSRect)rect {
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:8 yRadius:8];
    if (self.selectedPane) { [[NSColor.controlAccentColor colorWithAlphaComponent:.14] setFill]; [bg fill]; }
    else if (self.hovered) { [[NSColor.labelColor colorWithAlphaComponent:.06] setFill]; [bg fill]; }
    NSColor *ink = self.selectedPane ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
    NSImage *img = tinted(symbol(self.symbolName, 17, self.title), ink);
    NSSize is = img.size;
    CGFloat iconTop = 9 + round((22 - is.height) / 2);   // NSButton is flipped: y grows downward.
    [img drawInRect:NSMakeRect(round((self.bounds.size.width - is.width) / 2), self.flipped ? iconTop : self.bounds.size.height - iconTop - is.height, is.width, is.height)
           fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:self.selectedPane ? NSFontWeightSemibold : NSFontWeightRegular], NSForegroundColorAttributeName: self.selectedPane ? NSColor.controlAccentColor : NSColor.secondaryLabelColor};
    NSSize ts = [self.title sizeWithAttributes:a];
    CGFloat textY = self.flipped ? self.bounds.size.height - 8 - ts.height : 8;
    [self.title drawAtPoint:NSMakePoint(round((self.bounds.size.width - ts.width) / 2), textY) withAttributes:a];
}
@end

// A theme choice: a small live-looking card in the theme's colors. Selected = accent outline and a check badge.
@interface ThemeTile : NSControl
@property Theme *theme;
@property BOOL chosen, hovered;
@property NSTrackingArea *tracking;
@end
@implementation ThemeTile
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityRadioButtonRole; }
- (NSString *)accessibilityLabel { return [NSString stringWithFormat:T(@"主题：%@", @"Theme: %@"), self.theme.name]; }
- (id)accessibilityValue { return @(self.chosen); }
- (BOOL)accessibilityPerformPress { [self sendAction:self.action to:self.target]; return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingActiveAlways | NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)e { self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)e { self.hovered = NO; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)e { [self sendAction:self.action to:self.target]; }
- (void)keyDown:(NSEvent *)e { if ([e.characters isEqualToString:@" "]) [self sendAction:self.action to:self.target]; else [super keyDown:e]; }
- (void)drawRect:(NSRect)rect {
    Theme *th = self.theme;
    NSRect r = NSMakeRect(3, 22, self.bounds.size.width - 6, self.bounds.size.height - 25);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:10 yRadius:10];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:th.focusTop endingColor:th.focusBottom]; [g drawInBezierPath:p angle:-50];
    if (th.light) { [[NSColor.labelColor colorWithAlphaComponent:.12] setStroke]; p.lineWidth = 1; [p stroke]; }
    NSPoint c = NSMakePoint(NSMidX(r), NSMidY(r) + 2); CGFloat rad = MIN(r.size.width, r.size.height) * .34;
    NSBezierPath *track = [NSBezierPath bezierPath]; [track appendBezierPathWithArcWithCenter:c radius:rad startAngle:0 endAngle:360];
    track.lineWidth = 3; [[th.ink colorWithAlphaComponent:.14] setStroke]; [track stroke];
    NSBezierPath *arc = [NSBezierPath bezierPath]; [arc appendBezierPathWithArcWithCenter:c radius:rad startAngle:90 endAngle:-150 clockwise:YES];
    arc.lineWidth = 3; arc.lineCapStyle = NSLineCapStyleRound; [th.accentFocus setStroke]; [arc stroke];
    NSDictionary *ta = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium], NSForegroundColorAttributeName: th.ink};
    NSSize ts = [@"25:00" sizeWithAttributes:ta]; [@"25:00" drawAtPoint:NSMakePoint(c.x - ts.width / 2, c.y - ts.height / 2) withAttributes:ta];
    [th.accentRest setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMaxX(r) - 14, NSMinY(r) + 7, 6, 6)] fill];   // break accent dot
    if (self.chosen || self.hovered) {
        NSBezierPath *o = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, -2.5, -2.5) xRadius:12 yRadius:12];
        o.lineWidth = self.chosen ? 2.5 : 1.5; [(self.chosen ? NSColor.controlAccentColor : [NSColor.labelColor colorWithAlphaComponent:.25]) setStroke]; [o stroke];
    }
    NSDictionary *na = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:self.chosen ? NSFontWeightSemibold : NSFontWeightRegular], NSForegroundColorAttributeName: self.chosen ? NSColor.labelColor : NSColor.secondaryLabelColor};
    NSString *name = th.name; NSSize ns = [name sizeWithAttributes:na];
    [name drawAtPoint:NSMakePoint(round((self.bounds.size.width - ns.width) / 2), 2) withAttributes:na];
    if (self.chosen) {
        NSRect b = NSMakeRect(NSMaxX(r) - 20, NSMaxY(r) - 20, 16, 16);
        [NSColor.controlAccentColor setFill]; [[NSBezierPath bezierPathWithOvalInRect:b] fill];
        [tinted(symbol(@"checkmark", 8, nil), NSColor.whiteColor) drawInRect:NSInsetRect(b, 4, 4)];
    }
    if (self.window.firstResponder == self) { NSBezierPath *f = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, -4, -4) xRadius:13 yRadius:13]; f.lineWidth = 2; [NSColor.keyboardFocusIndicatorColor setStroke]; [f stroke]; }
}
@end

@interface SettingsWindow : NSWindow @end
@implementation SettingsWindow
- (void)cancelOperation:(id)sender { [self performClose:sender]; }   // Escape closes Settings (and asks about unsaved changes).
- (void)keyDown:(NSEvent *)e { if (e.keyCode == 53 && !self.attachedSheet) [self performClose:nil]; else [super keyDown:e]; }
@end

#pragma mark - App delegate

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate, NSMenuItemValidation, NSTextFieldDelegate>
// Card
@property CardWindow *panel;
@property CardView *card;
@property NSView *cardHost;
@property CALayer *cardShadow;
@property PassiveEffectView *effect;
@property ThemeSurface *surface;
@property RingView *ring;
@property NSImageView *phaseIcon;
@property NSTextField *phaseLabel, *roundsLabel, *timeLabel, *stateLabel;
@property GlowButton *startButton, *resetButton, *skipButton, *settingsButton, *hideButton, *compactButton;
@property CompletionOverlay *overlay;
// Menu bar
@property NSStatusItem *statusItem;
@property NSString *statusTitle, *statusToolTip, *statusImageKey;
@property BOOL statusDimmed;
@property NSMenu *statusMenu;
@property NSMenuItem *menuState, *menuToday, *menuToggle, *menuReset, *menuSkip, *menuCard, *menuCompact;
// State
@property NSUserDefaults *defaults;
@property NSTimer *ticker;
@property Countdown countdown;
@property NSInteger focusMinutes, breakMinutes, lastSeconds, statsSessions;
@property double sessionDuration, glassOpacity, statsFocusSeconds;
@property BOOL rest, started, autoBreak, autoFocus, notifications, pinned, showMenuTime, cardVisible, ambient;
@property BOOL menuOpen, menuRefresh, compact;
@property NSString *completionText, *completionShort, *statsDay, *soundName, *completionStyle, *themeKey, *languagePref;
@property NSPopUpButton *languagePopup;
@property NSButton *relaunchButton;
@property NSTextField *languageNote;
@property Theme *previewTheme;
@property double previewOpacity;   // < 0 = no preview
@property UNAuthorizationStatus authorization;
@property BOOL headless;    // No windows on screen, status item or timers (self-test, rendering).
@property BOOL sandboxed;   // No notifications, sounds, login items or real card position (all tests).
@property NSMutableArray<NSString *> *alertLog;
@property NSSound *playing;
// Settings
@property NSWindow *settingsWindow;
@property NSArray<PaneButton *> *paneButtons;
@property NSArray<NSView *> *panes;
@property NSView *paneHost;
@property NSInteger currentPane;
@property NSMutableDictionary *draft;
@property NSTextField *focusField, *breakField, *durationNote, *permissionLabel, *loginNote, *statusLabel, *versionLabel;
@property NSStepper *focusStepper, *breakStepper;
@property NSPopUpButton *completionPopup, *soundPopup;
@property NSButton *previewButton, *permissionButton, *saveButton, *revertButton, *restoreButton;
@property NSSwitch *autoBreakSwitch, *autoFocusSwitch, *notifySwitch, *ambientSwitch, *pinSwitch, *menuTimeSwitch, *loginSwitch;
@property NSView *autoStartGroup, *headerBar, *bottomBar;
@property NSNumber *previewAmbient;
@property BOOL fakeLogin;   // The login item state in tests (never touches the system).
@property NSArray<ThemeTile *> *themeTiles;
@property NSSlider *opacitySlider;
@property NSImageView *statusIcon;
@property NSInteger messageGeneration, saveGeneration;
@property BOOL showingError, durationInvalid;
@property NSString *lastSaved;
@end

@implementation AppDelegate

#pragma mark State

- (double)durationForRest:(BOOL)rest { return (rest ? self.breakMinutes : self.focusMinutes) * 60.0; }
- (Theme *)theme { return themeNamed(self.themeKey); }
- (Theme *)shownTheme { return self.previewTheme ?: self.theme; }
- (BOOL)overlayMode { return ![self.completionStyle isEqualToString:kBanner]; }

- (void)loadState {
    if (!self.alertLog) self.alertLog = [NSMutableArray array];
    self.previewOpacity = -1;
    NSUserDefaults *d = self.defaults;
    [d registerDefaults:@{kFocus: @25, kBreak: @5, kAutoBreak: @YES, kAutoFocus: @NO, kNotify: @YES, kSound: @YES, kPinned: @NO, kOpacity: @.45,
                          kMenuTime: @YES, kCardVisible: @YES, kCompletion: kOverlay, kTheme: @"aurora", kAmbient: @YES}];
    self.focusMinutes = boundedMinutes([d integerForKey:kFocus], 25);
    self.breakMinutes = boundedMinutes([d integerForKey:kBreak], 5);
    self.rest = [d boolForKey:kRest];
    self.autoBreak = [d boolForKey:kAutoBreak]; self.autoFocus = [d boolForKey:kAutoFocus];
    self.notifications = [d boolForKey:kNotify]; self.pinned = [d boolForKey:kPinned];
    // Version 3.0 stored a sound on/off switch; 3.1 stores the sound name ("none" = off).
    NSString *sound = [d stringForKey:kSoundName];
    self.soundName = sound ? validSound(sound) : ([d boolForKey:kSound] ? @"Glass" : @"none");
    self.completionStyle = [[d stringForKey:kCompletion] isEqualToString:kBanner] ? kBanner : kOverlay;
    self.themeKey = themeNamed([d stringForKey:kTheme]).key;
    self.ambient = [d boolForKey:kAmbient];
    NSString *lang = [d stringForKey:kLanguage];
    self.languagePref = [@[@"zh", @"en"] containsObject:lang] ? lang : @"system";
    self.showMenuTime = [d boolForKey:kMenuTime]; self.cardVisible = [d boolForKey:kCardVisible]; self.compact = [d boolForKey:kCompact];
    self.glassOpacity = boundedDouble([d doubleForKey:kOpacity], .1, .9, .45);
    // Restore the timer. Every stored value is checked, because preferences can be edited or damaged.
    double now = clockNow();
    double duration = boundedDouble([d doubleForKey:kDuration], kMinMinutes * 60, kMaxMinutes * 60, [self durationForRest:self.rest]);
    double remaining = [d objectForKey:kRemaining] ? [d doubleForKey:kRemaining] : duration;
    double deadline = [d doubleForKey:kEnd];
    if (!isfinite(deadline) || deadline < 0) deadline = 0;
    if (deadline > now + duration) deadline = now + duration;   // The system clock moved back.
    if (!isfinite(remaining) || remaining < 0 || remaining > duration) remaining = duration;
    BOOL wasStarted = [d boolForKey:kStarted];
    if (deadline == 0 && remaining <= 0 && !wasStarted) remaining = duration;
    self.sessionDuration = duration;
    self.countdown = (Countdown){remaining, deadline};
    self.started = deadline > 0 || remaining < duration || (wasStarted && remaining < duration);
    self.statsDay = [d stringForKey:kStatsDay];
    self.statsSessions = MAX(0, [d integerForKey:kStatsSessions]);
    self.statsFocusSeconds = boundedDouble([d doubleForKey:kStatsSeconds], 0, 86400 * 2, 0);
    [self rollStatsIfNeeded:now];
    self.lastSeconds = -1;
}

- (void)save {
    NSDictionary *values = @{kFocus: @(self.focusMinutes), kBreak: @(self.breakMinutes), kRest: @(self.rest), kStarted: @(self.started),
                             kRemaining: @(self.countdown.remaining), kEnd: @(self.countdown.deadline), kDuration: @(self.sessionDuration),
                             kAutoBreak: @(self.autoBreak), kAutoFocus: @(self.autoFocus), kNotify: @(self.notifications),
                             kSound: @(![self.soundName isEqualToString:@"none"]), kSoundName: self.soundName, kCompletion: self.completionStyle,
                             kTheme: self.themeKey, kAmbient: @(self.ambient), kLanguage: self.languagePref ?: @"system",
                             kPinned: @(self.pinned), kOpacity: @(self.glassOpacity), kMenuTime: @(self.showMenuTime), kCardVisible: @(self.cardVisible), kCompact: @(self.compact),
                             kStatsDay: self.statsDay ?: @"", kStatsSessions: @(self.statsSessions), kStatsSeconds: @(self.statsFocusSeconds)};
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) { [self.defaults setObject:value forKey:key]; }];
}

- (BOOL)rollStatsIfNeeded:(double)now {
    NSString *key = dayKey(now);
    if ([key isEqualToString:self.statsDay]) return NO;
    self.statsDay = key; self.statsSessions = 0; self.statsFocusSeconds = 0; return YES;
}

- (NSInteger)secondsRemaining { return MIN(secondsLeft(self.countdown, clockNow()), (NSInteger)ceil(self.sessionDuration)); }
- (BOOL)running { return self.countdown.deadline > 0; }
- (BOOL)paused { return self.started && !self.running; }

#pragma mark Ticking

- (void)updateTicker {
    if (self.headless) return;
    // Running: one tick per second, aligned to the moment the displayed second changes.
    // Idle or paused: no timer at all; midnight, wake and clock changes arrive as system notifications.
    [self.ticker invalidate]; self.ticker = nil;
    if (!self.running) return;
    double left = MAX(0, self.countdown.deadline - clockNow()), delay = fmod(left, 1.0) + .01;
    self.ticker = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:delay] interval:1 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    self.ticker.tolerance = .04; [NSRunLoop.mainRunLoop addTimer:self.ticker forMode:NSRunLoopCommonModes];
}

- (void)refresh { [self refreshForce:NO]; }
- (void)clockChanged { [self refreshForce:YES]; [self updateTicker]; }   // Wake from sleep, midnight or a system clock change.
- (void)refreshForce:(BOOL)force {
    double now = clockNow();
    Countdown c = self.countdown;
    if (finishTimer(&c, now)) { [self completePhaseEndedAt:self.countdown.deadline now:now]; force = YES; }
    if ([self rollStatsIfNeeded:now]) { [self save]; force = YES; }
    NSInteger seconds = [self secondsRemaining];
    if (!force && seconds == self.lastSeconds) return;
    self.lastSeconds = seconds;
    [self render:seconds];
}

- (void)completePhaseEndedAt:(double)end now:(double)now {
    BOOL finishedRest = self.rest, late = now - end > kLateGrace;
    if (!finishedRest) {
        [self rollStatsIfNeeded:end];   // Count the session on the day it ended.
        self.statsSessions += 1; self.statsFocusSeconds += self.sessionDuration;
        [self rollStatsIfNeeded:now];
    }
    self.rest = !finishedRest;
    self.sessionDuration = [self durationForRest:self.rest];
    self.countdown = (Countdown){self.sessionDuration, 0}; self.started = NO;
    // The completion prompt waits for the user. Only the "notification only" style can start the next phase by itself,
    // and never after a long sleep or a relaunch.
    BOOL autoStart = !late && !self.overlayMode && (self.rest ? self.autoBreak : self.autoFocus);
    if (autoStart) { Countdown n = self.countdown; startTimer(&n, now); self.countdown = n; self.started = YES; }
    if (late) self.completionText = [NSString stringWithFormat:finishedRest ? T(@"休息已于 %@ 结束", @"Break ended at %@") : T(@"专注已于 %@ 完成", @"Focus finished at %@"), clockText(end)];
    else self.completionText = finishedRest ? T(@"休息结束，准备下一轮专注", @"Break over. Ready to focus?") : T(@"专注完成，休息一下", @"Focus done. Take a break.");
    self.completionShort = late ? nil : finishedRest ? T(@"休息结束", @"Break over") : T(@"专注完成", @"Focus done");
    if (!late) [self alertFinishedRest:finishedRest autoStarted:autoStart];
    if (self.overlayMode) [self showCompletionFinishedRest:finishedRest late:late end:end];
    [self save]; [self updateTicker]; [self pulse];
}

#pragma mark Completion prompt

- (void)showCompletionFinishedRest:(BOOL)finishedRest late:(BOOL)late end:(double)end {
    if (!self.overlay) self.overlay = [CompletionOverlay new];
    self.overlay.headless = self.headless;
    __weak AppDelegate *weakSelf = self;
    self.overlay.onPrimary = ^{ [weakSelf overlayPrimary:nil]; };
    self.overlay.onSecondary = ^{ [weakSelf overlaySecondary:nil]; };
    NSString *title, *subtitle, *primary;
    if (!finishedRest) {
        title = T(@"该休息了", @"Time to Take a Break");
        subtitle = late ? [NSString stringWithFormat:T(@"专注已于 %@ 完成。休息 %ld 分钟后再继续。", @"Focus finished at %@. Take %ld minutes before you continue."), clockText(end), (long)self.breakMinutes]
                        : [NSString stringWithFormat:T(@"今天第 %ld 轮专注已完成。离开屏幕，休息 %ld 分钟。", @"Focus session %ld of today is done. Step away for %ld minutes."), (long)self.statsSessions, (long)self.breakMinutes];
        primary = [NSString stringWithFormat:T(@"开始休息 · %ld 分钟", @"Start Break · %ld min"), (long)self.breakMinutes];
    } else {
        title = T(@"准备好专注了吗？", @"Ready to Focus?");
        subtitle = late ? [NSString stringWithFormat:T(@"休息已于 %@ 结束。", @"Your break ended at %@."), clockText(end)]
                        : [NSString stringWithFormat:T(@"休息结束。下一轮专注 %ld 分钟。", @"Break is over. Next: %ld minutes of focus."), (long)self.focusMinutes];
        primary = [NSString stringWithFormat:T(@"开始专注 · %ld 分钟", @"Start Focus · %ld min"), (long)self.focusMinutes];
    }
    [self.overlay showTheme:self.theme nextRest:!finishedRest title:title subtitle:subtitle primary:primary secondary:T(@"稍后", @"Not Now")
                       hint:T(@"按 Return 开始 · 点击任意处或按 Esc 稍后", @"Return to start · Click anywhere or Esc for later") screen:self.panel.screen animate:!reduceMotion()];
}
- (void)overlayPrimary:(id)sender {   // Acknowledge and start the next phase.
    [self.overlay dismissAnimated:YES];
    if (!self.running) { Countdown c = self.countdown; if (c.remaining <= 0) c.remaining = self.sessionDuration; startTimer(&c, clockNow()); self.countdown = c; self.started = YES; self.completionText = nil; }
    [self save]; [self updateTicker]; [self refreshForce:YES];
}
- (void)overlaySecondary:(id)sender {   // Acknowledge; the next phase stays ready on the card.
    [self.overlay dismissAnimated:YES]; [self refreshForce:YES];
}
- (void)dismissOverlay { if (self.overlay.visible) [self.overlay dismissAnimated:YES]; }

#pragma mark Theme

- (void)applyThemeToCard {
    Theme *th = self.shownTheme;
    self.surface.theme = th; self.surface.rest = self.rest; self.surface.motion = (self.previewAmbient ? self.previewAmbient.boolValue : self.ambient) && !self.headless;
    self.surface.opacity = self.previewOpacity >= 0 ? self.previewOpacity : self.glassOpacity;
    [self.surface apply];
    self.effect.alphaValue = th.light ? .9 : .35;   // Frost lets more of the blurred desktop through.
    self.panel.appearance = [NSAppearance appearanceNamed:th.light ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    self.effect.appearance = [NSAppearance appearanceNamed:th.light ? NSAppearanceNameVibrantLight : NSAppearanceNameVibrantDark];
    self.ring.theme = th; self.ring.needsDisplay = YES;
    for (NSTextField *l in @[self.phaseLabel, self.timeLabel]) l.textColor = th.ink;
    for (NSTextField *l in @[self.stateLabel, self.roundsLabel]) l.textColor = th.mutedInk;
    for (GlowButton *b in @[self.startButton, self.resetButton, self.skipButton, self.settingsButton, self.hideButton, self.compactButton]) { b.theme = th; b.needsDisplay = YES; }
    [self updatePhaseLabel];
}

// The phase icon sits inside the phase text as an attachment. Its visible center (the symbol's alignment rect, not
// the padded image) is placed on the visible center of the actual glyphs, measured with Core Text, so icon and text line
// up for Chinese and Latin text alike. A fixed 5 pt gap separates them.
static CGFloat glyphMidY(NSString *text, NSFont *font) {
    NSAttributedString *t = [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: font}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)t);
    CGRect gb = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds); CFRelease(line);
    return CGRectGetMidY(gb);
}
- (void)updatePhaseLabel {
    Theme *th = self.shownTheme;
    NSFont *font = self.phaseLabel.font ?: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSString *phase = self.rest ? T(@"休息", @"Break") : T(@"专注", @"Focus");
    NSImage *raw = phaseSymbol(self.rest, 12), *icon = tinted(raw, [th accent:self.rest]);
    NSTextAttachment *att = [NSTextAttachment new]; att.image = icon;
    NSSize is = raw.size; CGFloat h = 13, scale = h / MAX(1, is.height), w = round(is.width * scale * 2) / 2;
    NSRect align = raw.alignmentRect; if (NSIsEmptyRect(align)) align = NSMakeRect(0, 0, is.width, is.height);
    CGFloat iconMid = NSMidY(align) * scale;   // visible center inside the attachment box
    att.bounds = NSMakeRect(0, round((glyphMidY(phase, font) - iconMid) * 2) / 2, w, h);
    NSMutableAttributedString *str = [[NSAttributedString attributedStringWithAttachment:att] mutableCopy];
    NSTextAttachment *gap = [NSTextAttachment new]; gap.bounds = NSMakeRect(0, 0, 6, 1);   // A fixed 6 pt gap (kerning after an attachment is not applied).
    gap.image = [NSImage imageWithSize:NSMakeSize(6, 1) flipped:NO drawingHandler:^BOOL(NSRect r) { return YES; }];
    [str appendAttributedString:[NSAttributedString attributedStringWithAttachment:gap]];
    [str appendAttributedString:[[NSAttributedString alloc] initWithString:phase attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: th.ink}]];
    self.phaseLabel.attributedStringValue = str; self.phaseLabel.tag = self.rest ? 2 : 1;
    [self.phaseLabel setAccessibilityLabel:phase];
    [self layoutHeader];
}

#pragma mark Rendering

// Only views whose content changed are touched: a running timer redraws the time, the ring and the
// menu bar title once per second and nothing else (performance test PF-01).
static void setText(NSTextField *f, NSString *s) { if (f && ![f.stringValue isEqualToString:s]) f.stringValue = s; }
static void setTitle(NSMenuItem *i, NSString *s) { if (i && ![i.title isEqualToString:s]) i.title = s; }

- (NSString *)roundsText { return [NSString stringWithFormat:T(@"今日 %ld 轮", @"%ld today"), (long)self.statsSessions]; }

- (void)render:(NSInteger)seconds {
    BOOL running = self.running, paused = self.paused;
    NSString *phase = self.rest ? T(@"休息", @"Break") : T(@"专注", @"Focus");
    NSString *time = timeString(seconds);
    BOOL headerChanged = NO;
    if (self.phaseLabel.tag != (self.rest ? 2 : 1)) { [self updatePhaseLabel]; headerChanged = YES; }
    if (![self.roundsLabel.stringValue isEqualToString:[self roundsText]]) { setText(self.roundsLabel, [self roundsText]); headerChanged = YES; }
    if (headerChanged) [self layoutHeader];
    setText(self.timeLabel, time);
    CGFloat timeAlpha = paused ? .6 : 1; if (self.timeLabel.alphaValue != timeAlpha) self.timeLabel.alphaValue = timeAlpha;
    setText(self.stateLabel, [self stateText]);
    NSString *primary = [self primaryTitle];
    if (![self.startButton.title isEqualToString:primary] || self.startButton.rest != self.rest || (self.startButton.image != nil) != self.compact) {
        self.startButton.title = primary; [self.startButton setAccessibilityLabel:primary]; self.startButton.toolTip = self.compact ? primary : nil;
        // Compact card: the primary button is a round play/pause icon; its accessible name stays the full text.
        self.startButton.image = self.compact ? symbol(running ? @"pause.fill" : @"play.fill", 17, primary) : nil;
        self.startButton.rest = self.rest; self.startButton.needsDisplay = YES;
    }
    if (self.resetButton.enabled != self.started) self.resetButton.enabled = self.started;
    NSString *skip = [self skipTitle];
    if (![self.skipButton.toolTip isEqualToString:skip]) { self.skipButton.toolTip = skip; [self.skipButton setAccessibilityLabel:skip]; }
    double progress = MAX(0, MIN(1, 1 - seconds / MAX(1, self.sessionDuration)));
    if (self.ring.progress != progress || self.ring.rest != self.rest || self.ring.dimmed != paused) {
        self.ring.progress = progress; self.ring.rest = self.rest; self.ring.dimmed = paused; self.ring.needsDisplay = YES;
    }
    if (self.surface.rest != self.rest) { self.surface.rest = self.rest; [self.surface apply]; }
    // Paused: the time can be double-clicked to change the length (pointer becomes a hand over it).
    NSRect editable = paused ? NSInsetRect(self.timeLabel.frame, -8, -6) : NSZeroRect;
    if (!NSEqualRects(editable, self.card.editableRect)) { self.card.editableRect = editable; [self.panel invalidateCursorRectsForView:self.card]; }
    // Menu bar: icon only when idle; the countdown appears once the timer starts.
    self.statusTitle = self.showMenuTime && self.started ? time : @"";
    self.statusDimmed = paused;
    self.statusToolTip = [self stateSummary:time];
    [self applyStatusItem];
    // The status menu text is refreshed when the menu opens (menuNeedsUpdate) and while it is open.
    if (self.headless || self.menuOpen || self.menuRefresh) {
        setTitle(self.menuState, self.statusToolTip);
        setTitle(self.menuToday, [NSString stringWithFormat:T(@"今日完成 %ld 轮 · 共 %ld 分钟", @"Today: %ld sessions · %ld min"), (long)self.statsSessions, (long)lround(self.statsFocusSeconds / 60)]);
        setTitle(self.menuToggle, primary); setTitle(self.menuSkip, skip);
        setTitle(self.menuCard, self.panel.visible ? T(@"隐藏卡片", @"Hide Card") : T(@"显示卡片", @"Show Card"));
        self.menuCompact.state = self.compact ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (self.settingsWindow.visible) [self updateDurationNote];
}

// Header: phase icon, phase name, and today's completed rounds right after it (muted).
- (void)layoutHeader {
    NSRect f = self.phaseLabel.frame;
    CGFloat w = ceil(self.phaseLabel.attributedStringValue.size.width) + 6;
    f.size.width = w; self.phaseLabel.frame = f;
    NSRect r = self.roundsLabel.frame; r.origin.x = NSMaxX(f) + 6; r.origin.y = f.origin.y + 1;
    r.size.width = MAX(20, (self.compact ? 200 : 172) - r.origin.x); self.roundsLabel.frame = r;
    self.roundsLabel.toolTip = [NSString stringWithFormat:T(@"今天已完成 %ld 轮专注", @"%ld focus sessions completed today"), (long)self.statsSessions];
}

// The compact card has 148 pt for the state: it uses the short form of each message (defect D-13).
- (NSString *)stateText {
    BOOL c = self.compact;
    if (self.running) return self.rest ? (c ? T(@"休息中", @"On break") : T(@"休息中，离开屏幕放松一下", @"Step away and rest your eyes")) : T(@"专注中", @"Focusing");
    if (self.paused) return c ? T(@"已暂停", @"Paused") : T(@"已暂停 · 双击时间可调整时长", @"Paused · double-click to edit");
    if (self.completionText) return c && self.completionShort ? self.completionShort : self.completionText;
    return c ? T(@"准备开始", @"Ready") : T(@"准备开始", @"Ready when you are");
}
- (NSString *)primaryTitle {
    return self.running ? T(@"暂停", @"Pause") : self.paused ? T(@"继续", @"Resume") : self.rest ? T(@"开始休息", @"Start Break") : T(@"开始专注", @"Start Focus");
}
- (NSString *)skipTitle { return self.rest ? T(@"跳过休息", @"Skip Break") : T(@"跳到休息", @"Skip to Break"); }
- (NSString *)stateSummary:(NSString *)time {
    if (self.running) return [NSString stringWithFormat:self.rest ? T(@"休息中 · 剩余 %@", @"On break · %@ left") : T(@"专注中 · 剩余 %@", @"Focusing · %@ left"), time];
    if (self.paused) return [NSString stringWithFormat:self.rest ? T(@"休息已暂停 · 剩余 %@", @"Break paused · %@ left") : T(@"专注已暂停 · 剩余 %@", @"Focus paused · %@ left"), time];
    return [NSString stringWithFormat:self.rest ? T(@"休息 · %@ · 未开始", @"Break · %@ · Not started") : T(@"专注 · %@ · 未开始", @"Focus · %@ · Not started"), time];
}

- (void)applyStatusItem {
    NSStatusBarButton *b = self.statusItem.button;
    if (!b) return;
    // Paused: a pause symbol replaces the phase icon (not only a dimmed color; defect D-04).
    NSString *imageKey = self.statusDimmed ? @"pause" : self.rest ? @"rest" : @"focus";
    if (![imageKey isEqualToString:self.statusImageKey]) {
        NSImage *pause = self.statusDimmed ? [[NSImage imageWithSystemSymbolName:@"pause.circle" accessibilityDescription:T(@"已暂停", @"Paused")]
                                              imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]] : nil;
        if (pause) pause.template = YES;
        b.image = pause ?: menuImage(self.rest); self.statusImageKey = imageKey;
    }
    NSString *title = self.statusTitle.length ? [@" " stringByAppendingString:self.statusTitle] : @"";
    if (![b.attributedTitle.string isEqualToString:title]) {
        b.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]}];
        b.imagePosition = title.length ? NSImageLeft : NSImageOnly;
    }
    if (![b.toolTip isEqualToString:self.statusToolTip]) { b.toolTip = self.statusToolTip; [b setAccessibilityLabel:[T(@"专注卡片：", @"FocusCard: ") stringByAppendingString:self.statusToolTip]]; }
}

- (void)pulse {
    if (self.headless || reduceMotion() || !self.panel.visible) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = .18; self.ring.animator.alphaValue = .25; }
                        completionHandler:^{ [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = .5; self.ring.animator.alphaValue = 1; }]; }];
}

#pragma mark Actions

- (void)toggle:(id)sender {
    [self refreshForce:NO];   // Complete a phase that expired while the Mac slept.
    [self dismissOverlay];
    double now = clockNow(); Countdown c = self.countdown;
    if (c.deadline > 0) pauseTimer(&c, now);
    else if (self.started && c.remaining <= 0) {   // Paused at 00:00 (a shorter length was saved while paused): finish the phase now.
        self.countdown = (Countdown){0, now}; [self refreshForce:YES]; return;
    } else { if (c.remaining <= 0) c.remaining = self.sessionDuration; startTimer(&c, now); [self ensureNotifications]; }
    self.countdown = c; self.started = YES; self.completionText = nil;
    [self save]; [self updateTicker]; [self refreshForce:YES];
}
- (void)reset:(id)sender {
    [self dismissOverlay];
    self.sessionDuration = [self durationForRest:self.rest];
    self.countdown = (Countdown){self.sessionDuration, 0}; self.started = NO; self.completionText = nil;
    [self save]; [self updateTicker]; [self refreshForce:YES];
}
- (void)skip:(id)sender { self.rest = !self.rest; [self reset:nil]; }
- (void)toggleCard:(id)sender { if (self.panel.visible) [self hideCard:nil]; else [self showCard:nil]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(reset:)) return self.started;
    return YES;
}

// Double-click on the time while paused opens Settings at the length of the current phase.
- (BOOL)handleDoubleClickAt:(NSPoint)p {
    if (!self.paused || !NSPointInRect(p, NSInsetRect(self.timeLabel.frame, -8, -6))) return NO;
    [self showSettingsPane:0 focusDuration:YES];
    return YES;
}

#pragma mark Card

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [PassiveLabel labelWithString:text]; label.frame = frame; label.font = [NSFont systemFontOfSize:size weight:weight];
    label.lineBreakMode = NSLineBreakByTruncatingTail; [self.card addSubview:label]; return label;
}
- (GlowButton *)button:(NSString *)title symbol:(NSString *)symbolName frame:(NSRect)frame action:(SEL)action primary:(BOOL)primary {
    GlowButton *b = [[GlowButton alloc] initWithFrame:frame]; b.title = title; b.primary = primary; b.bordered = NO; b.target = self; b.action = action;
    if (symbolName) { b.image = symbol(symbolName, frame.size.height >= 40 ? 15 : 13, title); b.toolTip = title; [b setAccessibilityLabel:title]; b.title = @""; }
    [self.card addSubview:b]; return b;
}

- (void)buildCard {
    self.card = [[CardView alloc] initWithFrame:NSMakeRect(0, 0, kCardW, kCardH)];
    self.card.wantsLayer = YES; self.card.layer.cornerRadius = 24; self.card.layer.masksToBounds = YES;
    __weak AppDelegate *weakSelf = self;
    self.card.onDoubleClick = ^BOOL(NSPoint p) { return [weakSelf handleDoubleClickAt:p]; };
    self.card.onClick = ^(NSPoint p) {   // Still Water: a gentle ripple where the card is touched.
        AppDelegate *s = weakSelf; if (s.shownTheme.ambient == AmbientRipple) [s.surface rippleAt:[s.surface convertPoint:p fromView:s.card] strength:1];
    };
    self.effect = [[PassiveEffectView alloc] initWithFrame:self.card.bounds];
    self.effect.material = NSVisualEffectMaterialHUDWindow; self.effect.blendingMode = NSVisualEffectBlendingModeBehindWindow; self.effect.state = NSVisualEffectStateActive; self.effect.alphaValue = .35;
    self.effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [self.card addSubview:self.effect];
    self.surface = [[ThemeSurface alloc] initWithFrame:self.card.bounds];
    self.surface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [self.card addSubview:self.surface];

    // Host: the card plus a transparent margin that holds the card's own soft shadow (no system shadow, no outline).
    self.cardHost = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kCardW + 2 * kPad, kCardH + 2 * kPad)]; self.cardHost.wantsLayer = YES;
    self.cardShadow = [CALayer layer]; self.cardShadow.shadowColor = NSColor.blackColor.CGColor; self.cardShadow.shadowOpacity = .28;
    self.cardShadow.shadowRadius = 16; self.cardShadow.shadowOffset = CGSizeMake(0, -7);
    self.cardShadow.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;   // follows the card while it animates
    [self.cardHost.layer addSublayer:self.cardShadow];
    self.card.frame = NSMakeRect(kPad, kPad, kCardW, kCardH); self.card.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.cardHost addSubview:self.card];
    self.panel = [[CardWindow alloc] initWithContentRect:self.cardHost.bounds styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    self.panel.title = T(@"专注卡片", @"FocusCard"); self.panel.opaque = NO; self.panel.backgroundColor = NSColor.clearColor; self.panel.hasShadow = NO;
    self.panel.releasedWhenClosed = NO; self.panel.canHide = NO;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.level = self.pinned ? NSFloatingWindowLevel : NSNormalWindowLevel - 1;
    self.panel.contentView = self.cardHost; self.panel.delegate = self;
    [self.panel setAccessibilityLabel:T(@"专注卡片", @"FocusCard")];

    // Header: phase icon and name, today's rounds; compact, settings and hide buttons (quiet until hovered).
    self.phaseIcon = [[NSImageView alloc] initWithFrame:NSZeroRect]; self.phaseIcon.imageScaling = NSImageScaleProportionallyDown; [self.card addSubview:self.phaseIcon];
    [self.phaseIcon setAccessibilityElement:NO]; self.phaseIcon.hidden = YES;   // Kept for layout code; the icon is drawn inline in the phase label.
    self.phaseLabel = [self label:@"" frame:NSZeroRect size:13 weight:NSFontWeightSemibold];
    self.roundsLabel = [self label:@"" frame:NSZeroRect size:12 weight:NSFontWeightRegular];
    self.compactButton = [self button:T(@"紧凑卡片", @"Compact card") symbol:@"arrow.down.right.and.arrow.up.left" frame:NSMakeRect(0, 0, 30, 30) action:@selector(toggleCompact:) primary:NO];
    self.settingsButton = [self button:T(@"设置", @"Settings") symbol:@"gearshape" frame:NSMakeRect(0, 0, 30, 30) action:@selector(showSettings:) primary:NO];
    self.hideButton = [self button:T(@"隐藏卡片（计时继续）", @"Hide card (timer keeps running)") symbol:@"minus" frame:NSMakeRect(0, 0, 30, 30) action:@selector(hideCard:) primary:NO];
    for (GlowButton *b in @[self.compactButton, self.settingsButton, self.hideButton]) b.quiet = YES;

    // Ring with time and state.
    self.ring = [[RingView alloc] initWithFrame:NSZeroRect]; self.ring.wantsLayer = YES; [self.card addSubview:self.ring];
    self.timeLabel = [self label:@"25:00" frame:NSZeroRect size:52 weight:NSFontWeightLight]; self.timeLabel.alignment = NSTextAlignmentCenter;
    self.stateLabel = [self label:@"" frame:NSZeroRect size:12 weight:NSFontWeightRegular]; self.stateLabel.alignment = NSTextAlignmentCenter;
    ((PassiveLabel *)self.timeLabel).axLabel = ^NSString *{ AppDelegate *s = weakSelf; NSInteger sec = [s secondsRemaining];
        return [NSString stringWithFormat:T(@"%@剩余 %ld 分 %ld 秒", @"%@, %ld min %ld s left"), s.rest ? T(@"休息", @"Break") : T(@"专注", @"Focus"), (long)sec / 60, (long)sec % 60]; };

    // Controls: reset, primary, skip.
    self.resetButton = [self button:T(@"重新计时", @"Reset") symbol:@"arrow.counterclockwise" frame:NSMakeRect(0, 0, 44, 44) action:@selector(reset:) primary:NO];
    self.startButton = [self button:@"" symbol:nil frame:NSZeroRect action:@selector(toggle:) primary:YES];
    self.skipButton = [self button:T(@"跳到休息", @"Skip to Break") symbol:@"forward.end.fill" frame:NSMakeRect(0, 0, 44, 44) action:@selector(skip:) primary:NO];

    [self layoutCard:NO];
    [self applyThemeToCard];
    self.panel.initialFirstResponder = self.startButton;
    NSRect screen = (NSScreen.mainScreen ?: NSScreen.screens.firstObject).visibleFrame;
    NSSize size = NSMakeSize(self.card.frame.size.width + 2 * kPad, self.card.frame.size.height + 2 * kPad);
    if (!self.sandboxed) [self.panel setFrameAutosaveName:kFrameName];   // Tests must not touch the real card position.
    if (self.sandboxed || ![self.panel setFrameUsingName:kFrameName]) [self.panel setFrameOrigin:NSMakePoint(NSMaxX(screen) - size.width - 32 + kPad, NSMaxY(screen) - size.height - 32 + kPad)];
    NSRect f = self.panel.frame; f.origin.y = NSMaxY(f) - size.height; f.size = size; [self.panel setFrame:f display:NO];
}

// Places every card view for the current mode. Full: 300 x 350 pt. Compact: 280 x 144 pt landscape strip.
- (void)layoutCard:(BOOL)animated {
    BOOL c = self.compact;
    NSSize size = c ? NSMakeSize(kCompactW, kCompactH) : NSMakeSize(kCardW, kCardH);
    CGFloat corner = c ? 20 : 24;
    NSDictionary<NSString *, NSValue *> *frames = c ? @{
        @"phaseIcon": [NSValue valueWithRect:NSZeroRect], @"phaseLabel": [NSValue valueWithRect:TOP(16, 12, 80, 20)],
        @"rounds": [NSValue valueWithRect:TOP(100, 13, 100, 18)],
        @"compact": [NSValue valueWithRect:TOP(206, 9, 28, 28)], @"settings": [NSValue valueWithRect:TOP(206, 9, 28, 28)],
        @"hide": [NSValue valueWithRect:TOP(240, 9, 28, 28)],
        @"ring": [NSValue valueWithRect:TOP(14, 42, 90, 90)], @"time": [NSValue valueWithRect:TOP(12, 72, 94, 30)],
        @"state": [NSValue valueWithRect:TOP(120, 52, 148, 16)],
        @"reset": [NSValue valueWithRect:TOP(124, 80, 36, 36)], @"start": [NSValue valueWithRect:TOP(172, 76, 44, 44)],
        @"skip": [NSValue valueWithRect:TOP(228, 80, 36, 36)],
    } : @{
        @"phaseIcon": [NSValue valueWithRect:NSZeroRect], @"phaseLabel": [NSValue valueWithRect:TOP(24, 20, 80, 20)],
        @"rounds": [NSValue valueWithRect:TOP(108, 21, 66, 18)],
        @"compact": [NSValue valueWithRect:TOP(176, 15, 30, 30)], @"settings": [NSValue valueWithRect:TOP(212, 15, 30, 30)],
        @"hide": [NSValue valueWithRect:TOP(248, 15, 30, 30)],
        @"ring": [NSValue valueWithRect:TOP(46, 58, 208, 208)], @"time": [NSValue valueWithRect:TOP(40, 122, 220, 64)],
        @"state": [NSValue valueWithRect:TOP(40, 188, 220, 18)],
        @"reset": [NSValue valueWithRect:TOP(24, 286, 44, 44)], @"start": [NSValue valueWithRect:TOP(78, 286, 144, 44)],
        @"skip": [NSValue valueWithRect:TOP(232, 286, 44, 44)],
    };
    NSDictionary<NSString *, NSView *> *views = @{@"phaseIcon": self.phaseIcon, @"phaseLabel": self.phaseLabel, @"rounds": self.roundsLabel, @"compact": self.compactButton,
        @"settings": self.settingsButton, @"hide": self.hideButton, @"ring": self.ring, @"time": self.timeLabel, @"state": self.stateLabel,
        @"reset": self.resetButton, @"start": self.startButton, @"skip": self.skipButton};
    NSSet *hiddenInCompact = [NSSet setWithArray:@[@"settings"]];
    // Compact keeps the essentials; Settings stays one click away in the menu bar (and Command-Comma).
    self.compactButton.image = symbol(c ? @"arrow.up.left.and.arrow.down.right" : @"arrow.down.right.and.arrow.up.left", c ? 12 : 13, nil);
    NSString *compactName = c ? T(@"标准卡片", @"Full card") : T(@"紧凑卡片", @"Compact card");
    self.compactButton.toolTip = compactName; [self.compactButton setAccessibilityLabel:compactName];
    self.timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:c ? 22 : 52 weight:NSFontWeightLight];
    self.startButton.round = c; self.startButton.needsDisplay = YES;
    for (GlowButton *b in @[self.compactButton, self.hideButton]) b.needsDisplay = YES;
    NSRect target = self.panel.frame;
    BOOL anchorRight = NO;
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen;
    if (screen) anchorRight = NSMidX(target) > NSMidX(screen.visibleFrame);   // Keep the card against the nearer screen edge.
    NSSize win = NSMakeSize(size.width + 2 * kPad, size.height + 2 * kPad);
    target.origin.x = anchorRight ? NSMaxX(target) - win.width : target.origin.x;
    target.origin.y = NSMaxY(target) - win.height; target.size = win;
    void (^apply)(BOOL) = ^(BOOL anim) {
        for (NSString *key in views) {
            NSView *v = anim ? views[key].animator : views[key];
            v.frame = frames[key].rectValue;
            v.alphaValue = c && [hiddenInCompact containsObject:key] ? 0 : 1;
        }
        if (anim) [self.panel.animator setFrame:target display:YES]; else [self.panel setFrame:target display:YES];
    };
    for (NSString *key in hiddenInCompact) views[key].hidden = NO;
    if (animated && !self.headless && !reduceMotion()) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = .28; ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            ctx.allowsImplicitAnimation = YES; apply(YES);
        } completionHandler:^{ [self finishLayout:corner]; }];
    } else { apply(NO); [self.card setFrameSize:size]; [self finishLayout:corner]; }
}
- (void)finishLayout:(CGFloat)corner {
    self.card.layer.cornerRadius = corner; self.surface.radius = corner; self.surface.needsLayout = YES;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.cardShadow.frame = self.card.frame;
    CGPathRef sp = CGPathCreateWithRoundedRect(CGRectMake(0, 0, self.card.frame.size.width, self.card.frame.size.height), corner, corner, NULL);
    self.cardShadow.shadowPath = sp; CGPathRelease(sp);
    [CATransaction commit];
    self.settingsButton.hidden = self.compact;   // Hidden views must not take clicks or keyboard focus.
    [self layoutHeader];
}
- (void)toggleCompact:(id)sender {
    self.compact = !self.compact; [self save];
    [self layoutCard:YES];
    self.lastSeconds = -1; [self refreshForce:YES];
}

- (void)showCard:(id)sender {
    BOOL onScreen = NO;
    for (NSScreen *screen in NSScreen.screens) if (NSIntersectsRect(self.panel.frame, NSInsetRect(screen.visibleFrame, 40, 40))) onScreen = YES;
    if (!onScreen) { NSRect s = (NSScreen.mainScreen ?: NSScreen.screens.firstObject).visibleFrame; NSSize z = self.panel.frame.size; [self.panel setFrameOrigin:NSMakePoint(NSMaxX(s) - z.width - 32, NSMaxY(s) - z.height - 32)]; }
    self.cardVisible = YES; [self save];
    if (self.headless) return;
    if (self.pinned) { [self activate]; [self.panel makeKeyAndOrderFront:nil]; [self.panel orderFrontRegardless]; }
    else [self.panel orderFront:nil];
    [self.surface updateMotion];
    [self refreshForce:YES];
}
- (void)hideCard:(id)sender { [self.panel orderOut:nil]; self.cardVisible = NO; [self save]; [self.surface updateMotion]; [self refreshForce:YES]; }
- (void)activate {
    if (@available(macOS 14.0, *)) [NSApp activate]; else [NSApp activateIgnoringOtherApps:YES];
}
- (void)windowDidMove:(NSNotification *)n { if (n.object == self.panel && !self.sandboxed) [self.panel saveFrameUsingName:kFrameName]; }
- (void)windowDidChangeOcclusionState:(NSNotification *)n { if (n.object == self.panel) [self.surface updateMotion]; }   // No motion when covered.

#pragma mark Menus

- (NSMenuItem *)item:(NSMenu *)menu title:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSMenuItem *i = [menu addItemWithTitle:title action:action keyEquivalent:key ?: @""]; if (action) i.target = self; return i;
}

- (void)buildMainMenu {
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [main addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *app = [[NSMenu alloc] initWithTitle:T(@"专注卡片", @"FocusCard")];
    NSMenuItem *about = [app addItemWithTitle:T(@"关于专注卡片", @"About FocusCard") action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""]; about.target = NSApp;
    [app addItem:NSMenuItem.separatorItem];
    [self item:app title:T(@"设置…", @"Settings…") action:@selector(showSettings:) key:@","];
    [app addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [app addItemWithTitle:T(@"退出专注卡片", @"Quit FocusCard") action:@selector(terminate:) keyEquivalent:@"q"]; quit.target = NSApp;
    appItem.submenu = app;
    // Edit menu: text fields in Settings need cut, copy, paste, undo and select all.
    NSMenuItem *editItem = [main addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:T(@"编辑", @"Edit")];
    [edit addItemWithTitle:T(@"撤销", @"Undo") action:NSSelectorFromString(@"undo:") keyEquivalent:@"z"];
    [edit addItemWithTitle:T(@"重做", @"Redo") action:NSSelectorFromString(@"redo:") keyEquivalent:@"Z"];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:T(@"剪切", @"Cut") action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:T(@"拷贝", @"Copy") action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:T(@"粘贴", @"Paste") action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:T(@"全选", @"Select All") action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    NSMenuItem *timerItem = [main addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *timer = [[NSMenu alloc] initWithTitle:T(@"计时", @"Timer")];
    [self item:timer title:T(@"重新计时", @"Reset") action:@selector(reset:) key:@"r"];
    NSMenuItem *skip = [self item:timer title:T(@"跳过当前阶段", @"Skip Phase") action:@selector(skip:) key:[NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey]];
    skip.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    timerItem.submenu = timer;
    NSMenuItem *windowItem = [main addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *window = [[NSMenu alloc] initWithTitle:T(@"窗口", @"Window")];
    [window addItemWithTitle:T(@"关闭", @"Close") action:@selector(performClose:) keyEquivalent:@"w"];
    windowItem.submenu = window;
    NSApp.mainMenu = main;
}

- (void)buildStatusMenu {
    NSMenu *menu = [NSMenu new]; menu.delegate = self; self.statusMenu = menu;
    self.menuState = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    self.menuToday = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    self.menuToggle = [self item:menu title:@"" action:@selector(toggle:) key:nil];
    self.menuReset = [self item:menu title:T(@"重新计时", @"Reset") action:@selector(reset:) key:nil];
    self.menuSkip = [self item:menu title:@"" action:@selector(skip:) key:nil];
    [menu addItem:NSMenuItem.separatorItem];
    self.menuCard = [self item:menu title:@"" action:@selector(toggleCard:) key:nil];
    self.menuCompact = [self item:menu title:T(@"紧凑卡片", @"Compact Card") action:@selector(toggleCompact:) key:nil];
    [self item:menu title:T(@"设置…", @"Settings…") action:@selector(showSettings:) key:@","];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:T(@"退出专注卡片", @"Quit FocusCard") action:@selector(terminate:) keyEquivalent:@"q"]; quit.target = NSApp;
    if (self.headless) return;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.autosaveName = @"FocusCardStatusItem";
    self.statusItem.menu = menu;
}
- (void)menuNeedsUpdate:(NSMenu *)menu { self.menuRefresh = YES; [self refreshForce:YES]; self.menuRefresh = NO; }
- (void)menuWillOpen:(NSMenu *)menu { self.menuOpen = YES; }
- (void)menuDidClose:(NSMenu *)menu { self.menuOpen = NO; }

#pragma mark Notifications and sound

- (void)readAuthorization {
    if (self.sandboxed) return;
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.authorization = settings.authorizationStatus; [self updatePermissionUI]; });
    }];
}
- (void)ensureNotifications {
    if (!self.notifications || self.sandboxed || self.authorization != UNAuthorizationStatusNotDetermined) return;
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                                                        completionHandler:^(BOOL granted, NSError *error) { [self readAuthorization]; }];
}
- (void)playSound:(NSString *)name {
    [self.playing stop]; self.playing = nil;
    if (self.sandboxed || [name isEqualToString:@"none"]) return;
    self.playing = [NSSound soundNamed:name]; [self.playing play];
}
- (void)alertFinishedRest:(BOOL)finishedRest autoStarted:(BOOL)autoStarted {
    NSString *title = finishedRest ? T(@"休息结束", @"Break over") : T(@"专注完成", @"Focus complete");
    NSString *body = finishedRest
        ? (autoStarted ? [NSString stringWithFormat:T(@"新一轮 %ld 分钟专注已开始。", @"Your %ld-minute focus has started."), (long)self.focusMinutes] : T(@"准备好后，开始下一轮专注。", @"Start the next focus when you are ready."))
        : (autoStarted ? [NSString stringWithFormat:T(@"%ld 分钟休息已开始。", @"Your %ld-minute break has started."), (long)self.breakMinutes] : [NSString stringWithFormat:T(@"准备好后，开始 %ld 分钟休息。", @"Start your %ld-minute break when you are ready."), (long)self.breakMinutes]);
    [self notifyTitle:title body:body];
}
- (void)notifyTitle:(NSString *)title body:(NSString *)body {
    [self.alertLog addObject:[NSString stringWithFormat:@"%@|%@|sound=%@|notify=%d", title, body, self.soundName, self.notifications]];
    if (self.sandboxed) return;
    [self playSound:self.soundName];
    if (!self.notifications) return;
    UNMutableNotificationContent *content = [UNMutableNotificationContent new]; content.title = title; content.body = body;
    // One identifier: a new alert replaces the previous one instead of piling up in Notification Center.
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:kNotificationID content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        if (error) { NSLog(@"FocusCard notification error: %@", error.localizedDescription); [self readAuthorization]; }
    }];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completion {
    // The full-screen prompt is already on screen: keep the notification in Notification Center only.
    completion(self.overlay.visible ? UNNotificationPresentationOptionList : UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{ [self showCard:nil]; }); completion();
}

static const CGFloat kSettingsW = 520, kSettingsTop = 74, kSettingsBottom = 58;

#pragma mark Settings: values and draft

// Settings are edited as a draft. Theme, background and ambient motion preview live on the card; nothing is
// stored until Save. Revert (or closing with Don't Save) drops the draft.
- (BOOL)loginEnabled {
    if (self.sandboxed) return self.fakeLogin;
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    return status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval;
}
- (NSDictionary *)currentValues {
    return @{kFocus: @(self.focusMinutes), kBreak: @(self.breakMinutes), kAutoBreak: @(self.autoBreak), kAutoFocus: @(self.autoFocus),
             kNotify: @(self.notifications), kSoundName: self.soundName, kCompletion: self.completionStyle, kTheme: self.themeKey,
             kAmbient: @(self.ambient), kPinned: @(self.pinned), kOpacity: @(self.glassOpacity), kMenuTime: @(self.showMenuTime), kLanguage: self.languagePref ?: @"system", kLogin: @([self loginEnabled])};
}
- (NSDictionary *)defaultValues {
    return @{kFocus: @25, kBreak: @5, kAutoBreak: @YES, kAutoFocus: @NO, kNotify: @YES, kSoundName: @"Glass", kCompletion: kOverlay, kTheme: @"aurora",
             kAmbient: @YES, kPinned: @NO, kOpacity: @.45, kMenuTime: @YES, kLanguage: @"system", kLogin: @([self loginEnabled])};
}
- (BOOL)settingsDirty {
    if (!self.draft) return NO;
    NSDictionary *cur = [self currentValues];
    for (NSString *k in cur) if (![cur[k] isEqual:self.draft[k]]) return YES;
    return NO;
}
- (NSArray<NSString *> *)dirtyKeys {
    NSMutableArray *keys = [NSMutableArray array]; NSDictionary *cur = [self currentValues];
    for (NSString *k in cur) if (self.draft && ![cur[k] isEqual:self.draft[k]]) [keys addObject:k];
    return [keys sortedArrayUsingSelector:@selector(compare:)];
}
- (void)setDraftValue:(id)value forKey:(NSString *)key {
    if (!self.draft) self.draft = [[self currentValues] mutableCopy];
    self.draft[key] = value;
    if ([key isEqualToString:kTheme] || [key isEqualToString:kOpacity] || [key isEqualToString:kAmbient]) [self previewDraft];
    if ([key isEqualToString:kCompletion]) [self updateAutoStartVisibility:YES];
    if ([key isEqualToString:kNotify]) [self updatePermissionUI];
    [self updateSaveBar];
}
- (void)previewDraft {   // Live preview on the card; the stored theme stays until Save.
    Theme *th = themeNamed(self.draft[kTheme]);
    self.previewTheme = [th.key isEqualToString:self.themeKey] ? nil : th;
    double op = [self.draft[kOpacity] doubleValue];
    self.previewOpacity = op == self.glassOpacity ? -1 : op;
    BOOL amb = [self.draft[kAmbient] boolValue];
    self.previewAmbient = amb == self.ambient ? nil : @(amb);
    [self applyThemeToCard];
}
- (void)clearPreview {
    BOOL had = self.previewTheme || self.previewOpacity >= 0 || self.previewAmbient;
    self.previewTheme = nil; self.previewOpacity = -1; self.previewAmbient = nil;
    if (had) [self applyThemeToCard];
}

#pragma mark Settings: building

- (NSTextField *)note:(NSString *)text width:(CGFloat)width {
    NSTextField *l = [NSTextField wrappingLabelWithString:text]; l.font = [NSFont systemFontOfSize:11]; l.textColor = NSColor.secondaryLabelColor;
    l.preferredMaxLayoutWidth = width; l.selectable = NO; return l;
}
- (NSTextField *)caption:(NSString *)text {
    NSTextField *l = [NSTextField labelWithString:text]; l.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]; l.textColor = NSColor.secondaryLabelColor; return l;
}
// One row: title (and an optional detail line) on the left, the control on the right. Minimum height 44 pt.
- (NSView *)rowTitle:(id)title detail:(NSTextField *)detail control:(NSView *)control {
    NSTextField *t = [title isKindOfClass:NSTextField.class] ? title : [NSTextField labelWithString:title];
    if (![title isKindOfClass:NSTextField.class]) t.font = [NSFont systemFontOfSize:13];
    NSStackView *texts = [NSStackView stackViewWithViews:detail ? @[t, detail] : @[t]];
    texts.orientation = NSUserInterfaceLayoutOrientationVertical; texts.alignment = NSLayoutAttributeLeading; texts.spacing = 2;
    NSView *row = [NSView new];
    for (NSView *v in @[texts, control]) { v.translatesAutoresizingMaskIntoConstraints = NO; [row addSubview:v]; }
    [texts setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [texts setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [control setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [texts.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [texts.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [texts.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:9],
        [control.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [control.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [control.leadingAnchor constraintGreaterThanOrEqualToAnchor:texts.trailingAnchor constant:12],
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [row.heightAnchor constraintGreaterThanOrEqualToAnchor:texts.heightAnchor constant:18],
    ]];
    if (detail) detail.preferredMaxLayoutWidth = 300;
    return row;
}
- (GroupBox *)group:(NSArray<NSView *> *)rows {
    GroupBox *g = [GroupBox new];
    NSMutableArray *views = [NSMutableArray array];
    for (NSView *r in rows) {
        if (views.count) { Hairline *h = [Hairline new]; [h.heightAnchor constraintEqualToConstant:1].active = YES; [views addObject:h]; }
        [views addObject:r];
    }
    NSStackView *s = [NSStackView stackViewWithViews:views]; s.orientation = NSUserInterfaceLayoutOrientationVertical; s.spacing = 0; s.alignment = NSLayoutAttributeLeading;
    s.translatesAutoresizingMaskIntoConstraints = NO; [g addSubview:s];
    [NSLayoutConstraint activateConstraints:@[[s.topAnchor constraintEqualToAnchor:g.topAnchor], [s.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
                                              [s.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [s.trailingAnchor constraintEqualToAnchor:g.trailingAnchor]]];
    for (NSView *v in views) {
        if ([v isKindOfClass:Hairline.class]) { [v.leadingAnchor constraintEqualToAnchor:s.leadingAnchor constant:14].active = YES; [v.trailingAnchor constraintEqualToAnchor:s.trailingAnchor].active = YES; }
        else [v.widthAnchor constraintEqualToAnchor:s.widthAnchor].active = YES;
    }
    return g;
}
- (NSStackView *)paneWith:(NSArray<NSView *> *)items {
    NSStackView *s = [NSStackView stackViewWithViews:items]; s.orientation = NSUserInterfaceLayoutOrientationVertical; s.alignment = NSLayoutAttributeLeading; s.spacing = 8;
    s.edgeInsets = NSEdgeInsetsMake(18, 24, 20, 24);
    for (NSView *v in items) if ([v isKindOfClass:GroupBox.class] || [v isKindOfClass:NSGridView.class] || v == self.durationNote || v == self.autoStartGroup)
        [v.widthAnchor constraintEqualToConstant:kSettingsW - 48].active = YES;
    for (NSView *v in items) if ([v isKindOfClass:NSTextField.class] && ![(NSTextField *)v isEditable]) {
        NSView *prev = items[MAX(0, (NSInteger)[items indexOfObject:v] - 1)];
        if (prev != v && [prev isKindOfClass:GroupBox.class]) [s setCustomSpacing:18 afterView:prev];   // A caption starts a new section.
    }
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}
- (NSSwitch *)toggle:(NSString *)key label:(NSString *)ax {
    NSSwitch *s = [NSSwitch new]; s.target = self; s.action = @selector(switchChanged:); s.identifier = key; s.controlSize = NSControlSizeSmall;
    [s setAccessibilityLabel:ax]; return s;
}
- (NSStackView *)durationControl:(NSTextField * __strong *)fieldOut stepper:(NSStepper * __strong *)stepperOut tag:(NSInteger)tag axLabel:(NSString *)ax {
    NSTextField *field = [NSTextField textFieldWithString:@""]; field.alignment = NSTextAlignmentRight; field.delegate = self;
    field.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular]; field.bezelStyle = NSTextFieldRoundedBezel;
    [field.widthAnchor constraintEqualToConstant:56].active = YES;
    field.target = self; field.action = @selector(durationEdited:); field.cell.sendsActionOnEndEditing = YES; field.tag = tag;
    [field setAccessibilityLabel:ax];
    NSStepper *step = [NSStepper new]; step.minValue = kMinMinutes; step.maxValue = kMaxMinutes; step.increment = 1; step.valueWraps = NO; step.autorepeat = YES;
    step.target = self; step.action = @selector(stepDuration:); step.tag = tag; [step setAccessibilityLabel:ax];
    NSTextField *unit = [NSTextField labelWithString:T(@"分钟", @"min")]; unit.textColor = NSColor.secondaryLabelColor;
    *fieldOut = field; *stepperOut = step;
    NSStackView *s = [NSStackView stackViewWithViews:@[field, step, unit]]; s.spacing = 4; return s;
}


- (NSView *)timerPane {
    NSStackView *focusRow = [self durationControl:&_focusField stepper:&_focusStepper tag:0 axLabel:T(@"专注时长（分钟）", @"Focus length in minutes")];
    NSStackView *breakRow = [self durationControl:&_breakField stepper:&_breakStepper tag:1 axLabel:T(@"休息时长（分钟）", @"Break length in minutes")];
    self.durationNote = [self note:@"" width:kSettingsW - 60];
    GroupBox *lengths = [self group:@[[self rowTitle:T(@"专注时长", @"Focus") detail:nil control:focusRow], [self rowTitle:T(@"休息时长", @"Break") detail:nil control:breakRow]]];
    self.autoBreakSwitch = [self toggle:kAutoBreak label:T(@"专注结束后自动开始休息", @"Start break automatically")];
    self.autoFocusSwitch = [self toggle:kAutoFocus label:T(@"休息结束后自动开始专注", @"Start focus automatically")];
    GroupBox *autos = [self group:@[[self rowTitle:T(@"专注结束后开始休息", @"Start break after focus") detail:nil control:self.autoBreakSwitch],
                                    [self rowTitle:T(@"休息结束后开始专注", @"Start focus after break") detail:nil control:self.autoFocusSwitch]]];
    NSStackView *autoStack = [NSStackView stackViewWithViews:@[[self caption:T(@"自动开始（仅通知模式）", @"Auto start (notification only)")], autos]];
    autoStack.orientation = NSUserInterfaceLayoutOrientationVertical; autoStack.alignment = NSLayoutAttributeLeading; autoStack.spacing = 8;
    [autos.widthAnchor constraintEqualToAnchor:autoStack.widthAnchor].active = YES;
    self.autoStartGroup = autoStack;
    NSStackView *pane = [self paneWith:@[[self caption:T(@"时长", @"Length")], lengths, self.durationNote, self.autoStartGroup]];
    [pane setCustomSpacing:18 afterView:self.durationNote];
    return pane;
}
- (NSView *)alertsPane {
    self.completionPopup = [NSPopUpButton new]; self.completionPopup.target = self; self.completionPopup.action = @selector(completionChosen:);
    [self.completionPopup addItemsWithTitles:@[T(@"全屏提示（推荐）", @"Full-screen prompt (recommended)"), T(@"仅系统通知", @"Notification only")]];
    self.completionPopup.itemArray[0].representedObject = kOverlay; self.completionPopup.itemArray[1].representedObject = kBanner;
    [self.completionPopup setAccessibilityLabel:T(@"阶段结束时的提示", @"Prompt when a phase ends")];
    self.soundPopup = [NSPopUpButton new]; self.soundPopup.target = self; self.soundPopup.action = @selector(soundChosen:);
    for (NSArray *s in allSounds()) { [self.soundPopup addItemWithTitle:T(s[1], s[2])]; self.soundPopup.lastItem.representedObject = s[0]; }
    [self.soundPopup setAccessibilityLabel:T(@"提示音", @"Sound")];
    self.previewButton = [NSButton buttonWithImage:symbol(@"play.fill", 11, T(@"试听", @"Preview")) target:self action:@selector(previewSound:)];
    self.previewButton.bezelStyle = NSBezelStyleRounded; self.previewButton.toolTip = T(@"试听", @"Preview"); [self.previewButton setAccessibilityLabel:T(@"试听提示音", @"Preview sound")];
    NSStackView *sound = [NSStackView stackViewWithViews:@[self.soundPopup, self.previewButton]]; sound.spacing = 6;
    self.notifySwitch = [self toggle:kNotify label:T(@"发送系统通知", @"Show a notification")];
    self.permissionLabel = [self note:@"" width:300];
    self.permissionButton = [NSButton buttonWithTitle:@"" target:self action:@selector(permissionAction:)]; self.permissionButton.controlSize = NSControlSizeSmall;
    self.permissionButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    GroupBox *prompt = [self group:@[[self rowTitle:T(@"结束时", @"When a phase ends") detail:[self note:T(@"全屏提示会等你确认后再开始下一段。", @"The full-screen prompt waits for you before the next phase.") width:300] control:self.completionPopup],
                                     [self rowTitle:T(@"提示音", @"Sound") detail:nil control:sound]]];
    GroupBox *notify = [self group:@[[self rowTitle:T(@"系统通知", @"Notifications") detail:self.permissionLabel control:self.notifySwitch],
                                     [self rowTitle:T(@"通知权限", @"Permission") detail:nil control:self.permissionButton]]];
    return [self paneWith:@[[self caption:T(@"完成提示", @"Completion")], prompt, [self caption:T(@"通知", @"Notifications")], notify]];
}
- (NSView *)appearancePane {
    NSMutableArray *tiles = [NSMutableArray array], *rows = [NSMutableArray array], *row = [NSMutableArray array];
    for (Theme *th in allThemes()) {
        ThemeTile *t = [[ThemeTile alloc] initWithFrame:NSMakeRect(0, 0, 146, 104)]; t.theme = th; t.target = self; t.action = @selector(themeChosen:);
        [t.widthAnchor constraintEqualToConstant:146].active = YES; [t.heightAnchor constraintEqualToConstant:104].active = YES;
        t.toolTip = th.name; [tiles addObject:t]; [row addObject:t];
        if (row.count == 3) { [rows addObject:row]; row = [NSMutableArray array]; }
    }
    self.themeTiles = tiles;
    NSGridView *grid = [NSGridView gridViewWithViews:rows]; grid.rowSpacing = 10; grid.columnSpacing = 12;
    grid.xPlacement = NSGridCellPlacementCenter;
    self.ambientSwitch = [self toggle:kAmbient label:T(@"环境动效", @"Ambient motion")];
    self.opacitySlider = [NSSlider sliderWithValue:self.glassOpacity minValue:.1 maxValue:.9 target:self action:@selector(opacityChanged:)];
    self.opacitySlider.continuous = YES; [self.opacitySlider.widthAnchor constraintEqualToConstant:160].active = YES; self.opacitySlider.controlSize = NSControlSizeSmall;
    [self.opacitySlider setAccessibilityLabel:T(@"卡片背景不透明度", @"Card background opacity")];
    NSTextField *lo = [NSTextField labelWithString:T(@"通透", @"Clear")], *hi = [NSTextField labelWithString:T(@"浓郁", @"Solid")];
    lo.font = hi.font = [NSFont systemFontOfSize:11]; lo.textColor = hi.textColor = NSColor.secondaryLabelColor;
    NSStackView *opacity = [NSStackView stackViewWithViews:@[lo, self.opacitySlider, hi]]; opacity.spacing = 8;
    self.pinSwitch = [self toggle:kPinned label:T(@"显示在其他窗口上方", @"Keep above other windows")];
    GroupBox *card = [self group:@[
        [self rowTitle:T(@"环境动效", @"Ambient motion") detail:[self note:T(@"非常轻微。开启“减少动态效果”或卡片被遮挡时自动停止。", @"Very subtle. Stops with Reduce Motion or when the card is covered.") width:300] control:self.ambientSwitch],
        [self rowTitle:T(@"背景", @"Background") detail:nil control:opacity],
        [self rowTitle:T(@"显示在其他窗口上方", @"Keep above other windows") detail:[self note:T(@"关闭时，其他应用窗口始终显示在卡片上方。", @"When off, other app windows stay above the card.") width:300] control:self.pinSwitch]]];
    return [self paneWith:@[[self caption:T(@"主题", @"Theme")], grid, [self caption:T(@"卡片", @"Card")], card]];
}
- (NSView *)generalPane {
    self.menuTimeSwitch = [self toggle:kMenuTime label:T(@"菜单栏显示剩余时间", @"Show time left in the menu bar")];
    self.loginSwitch = [self toggle:kLogin label:T(@"登录时打开", @"Open at login")];
    self.loginNote = [self note:@"" width:300];
    GroupBox *g = [self group:@[[self rowTitle:T(@"菜单栏显示剩余时间", @"Time left in the menu bar") detail:[self note:T(@"计时开始后显示；空闲时只显示图标。", @"Shown while a timer is on; idle shows only the icon.") width:300] control:self.menuTimeSwitch],
                                [self rowTitle:T(@"登录时打开", @"Open at login") detail:self.loginNote control:self.loginSwitch]]];
    self.languagePopup = [NSPopUpButton new]; self.languagePopup.target = self; self.languagePopup.action = @selector(languageChosen:);
    // Each name is written in its own language, so a person can always find theirs.
    NSArray *langs = @[@[@"system", T(@"跟随系统", @"System")], @[@"zh", @"简体中文"], @[@"en", @"English"]];
    for (NSArray *l in langs) { [self.languagePopup addItemWithTitle:l[1]]; self.languagePopup.lastItem.representedObject = l[0]; }
    [self.languagePopup setAccessibilityLabel:T(@"语言", @"Language")];
    self.relaunchButton = [NSButton buttonWithTitle:T(@"立即重新打开", @"Relaunch Now") target:self action:@selector(relaunch:)];
    self.relaunchButton.controlSize = NSControlSizeSmall; self.relaunchButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.languageNote = [self note:@"" width:300];
    NSStackView *langControl = [NSStackView stackViewWithViews:@[self.relaunchButton, self.languagePopup]]; langControl.spacing = 8;
    GroupBox *language = [self group:@[[self rowTitle:T(@"语言 · Language", @"Language · 语言") detail:self.languageNote control:langControl]]];
    self.restoreButton = [NSButton buttonWithTitle:T(@"恢复默认设置", @"Restore Defaults") target:self action:@selector(restoreDefaults:)];
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"3.1";
    GroupBox *reset = [self group:@[[self rowTitle:T(@"恢复默认设置", @"Restore defaults") detail:[self note:T(@"先放入草稿，保存后才生效。", @"Fills the draft; nothing changes until you save.") width:300] control:self.restoreButton]]];
    self.versionLabel = [self note:[NSString stringWithFormat:T(@"专注卡片 %@ · 所有数据只保存在这台 Mac 上", @"FocusCard %@ · All data stays on this Mac"), version] width:kSettingsW - 60];
    return [self paneWith:@[[self caption:T(@"通用", @"General")], g, [self caption:T(@"语言", @"Language")], language, reset, self.versionLabel]];
}

- (void)buildSettings {
    if (self.settingsWindow) return;
    NSWindow *w = [[SettingsWindow alloc] initWithContentRect:NSMakeRect(0, 0, kSettingsW, 400) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                                      backing:NSBackingStoreBuffered defer:NO];
    w.title = T(@"专注卡片设置", @"FocusCard Settings"); w.titlebarAppearsTransparent = YES; w.titleVisibility = NSWindowTitleHidden;
    w.releasedWhenClosed = NO; w.delegate = self; self.settingsWindow = w;
    NSView *content = w.contentView;
    // Tab strip under the (transparent) title bar.
    NSArray *specs = @[@[@"timer", T(@"计时", @"Timer")], @[@"bell", T(@"提醒", @"Alerts")], @[@"paintpalette", T(@"外观", @"Appearance")], @[@"gearshape", T(@"通用", @"General")]];
    NSMutableArray *buttons = [NSMutableArray array];
    self.headerBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 400 - kSettingsTop - 26, kSettingsW, kSettingsTop)];
    self.headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    CGFloat bw = 84, x0 = round((kSettingsW - bw * specs.count) / 2);
    for (NSUInteger i = 0; i < specs.count; i++) {
        PaneButton *b = [[PaneButton alloc] initWithFrame:NSMakeRect(x0 + bw * i, 8, bw, 58)]; b.symbolName = specs[i][0]; b.title = specs[i][1];
        b.bordered = NO; b.tag = i; b.target = self; b.action = @selector(paneChosen:); [b setAccessibilityLabel:specs[i][1]];
        [self.headerBar addSubview:b]; [buttons addObject:b];
    }
    Hairline *topLine = [[Hairline alloc] initWithFrame:NSMakeRect(0, 0, kSettingsW, 1)]; topLine.autoresizingMask = NSViewWidthSizable; [self.headerBar addSubview:topLine];
    self.paneButtons = buttons;
    // Save bar.
    self.bottomBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSettingsW, kSettingsBottom)]; self.bottomBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    Hairline *bottomLine = [[Hairline alloc] initWithFrame:NSMakeRect(0, kSettingsBottom - 1, kSettingsW, 1)]; bottomLine.autoresizingMask = NSViewWidthSizable; [self.bottomBar addSubview:bottomLine];
    self.statusIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(22, 21, 16, 16)]; [self.bottomBar addSubview:self.statusIcon];
    self.statusLabel = [NSTextField labelWithString:@""]; self.statusLabel.frame = NSMakeRect(44, 20, 240, 17); self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail; [self.bottomBar addSubview:self.statusLabel];
    self.saveButton = [NSButton buttonWithTitle:T(@"保存", @"Save") target:self action:@selector(saveSettings:)]; self.saveButton.keyEquivalent = @"\r";
    self.revertButton = [NSButton buttonWithTitle:T(@"还原", @"Revert") target:self action:@selector(revertSettings:)];
    self.revertButton.toolTip = T(@"放弃未保存的更改", @"Discard unsaved changes");
    [self.saveButton sizeToFit]; [self.revertButton sizeToFit];
    NSSize sv = self.saveButton.frame.size, rv = self.revertButton.frame.size;
    CGFloat sw = MAX(84, sv.width), rw = MAX(76, rv.width);
    self.saveButton.frame = NSMakeRect(kSettingsW - 20 - sw, round((kSettingsBottom - sv.height) / 2), sw, sv.height);
    self.revertButton.frame = NSMakeRect(NSMinX(self.saveButton.frame) - 8 - rw, round((kSettingsBottom - rv.height) / 2), rw, rv.height);
    for (NSButton *b in @[self.saveButton, self.revertButton]) { b.autoresizingMask = NSViewMinXMargin; [self.bottomBar addSubview:b]; }
    // Pane host between the two.
    self.paneHost = [[NSView alloc] initWithFrame:NSMakeRect(0, kSettingsBottom, kSettingsW, 400 - kSettingsBottom - kSettingsTop - 26)];
    self.paneHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    for (NSView *v in @[self.paneHost, self.headerBar, self.bottomBar]) [content addSubview:v];
    self.panes = @[[self timerPane], [self alertsPane], [self appearancePane], [self generalPane]];
    self.currentPane = -1;
    [self selectPane:0 animate:NO];
    [w center];
}

- (CGFloat)titleBarHeight { return self.settingsWindow.frame.size.height - [self.settingsWindow contentLayoutRect].size.height; }
- (CGFloat)heightForPane:(NSView *)pane {
    NSLayoutConstraint *wc = [pane.widthAnchor constraintEqualToConstant:kSettingsW]; wc.active = YES;
    [pane layoutSubtreeIfNeeded]; CGFloat h = pane.fittingSize.height; wc.active = NO;
    return ceil(h);
}
- (void)selectPane:(NSInteger)index animate:(BOOL)animate {
    index = MAX(0, MIN(3, index));
    NSView *pane = self.panes[index];
    if (index != self.currentPane) {
        for (NSView *v in self.paneHost.subviews.copy) [v removeFromSuperview];
        [self.paneHost addSubview:pane];
        [NSLayoutConstraint activateConstraints:@[[pane.topAnchor constraintEqualToAnchor:self.paneHost.topAnchor],
                                                  [pane.leadingAnchor constraintEqualToAnchor:self.paneHost.leadingAnchor],
                                                  [pane.trailingAnchor constraintEqualToAnchor:self.paneHost.trailingAnchor]]];
        self.currentPane = index;
        if (!self.headless && animate && !reduceMotion()) {   // A short cross-fade of the new pane.
            pane.alphaValue = 0;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = .2; pane.animator.alphaValue = 1; }];
        } else pane.alphaValue = 1;
    }
    for (PaneButton *b in self.paneButtons) { b.selectedPane = b.tag == index; b.needsDisplay = YES; }
    [self.settingsWindow setTitle:[NSString stringWithFormat:@"%@ · %@", T(@"专注卡片设置", @"FocusCard Settings"), self.paneButtons[index].title]];
    [self resizeSettings:animate];
    NSView *first = @[self.focusField, self.completionPopup, self.themeTiles.firstObject ?: NSNull.null, self.menuTimeSwitch][index];
    if ([first isKindOfClass:NSView.class]) self.settingsWindow.initialFirstResponder = first;
}
- (void)resizeSettings:(BOOL)animate {
    NSView *pane = self.panes[self.currentPane];
    CGFloat contentH = kSettingsTop + [self heightForPane:pane] + kSettingsBottom + 26;   // 26: the transparent title bar.
    NSRect f = self.settingsWindow.frame;
    NSRect target = [self.settingsWindow frameRectForContentRect:NSMakeRect(0, 0, kSettingsW, contentH)];
    target.origin.x = f.origin.x; target.origin.y = NSMaxY(f) - target.size.height;   // Keep the top edge still.
    if (NSEqualRects(target, f)) return;
    if (animate && !self.headless && !reduceMotion() && self.settingsWindow.visible) {   // Non-blocking: events keep flowing during the resize.
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = .22; ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [self.settingsWindow.animator setFrame:target display:YES]; }];
    } else [self.settingsWindow setFrame:target display:YES];
}
- (void)paneChosen:(PaneButton *)sender { [self selectPane:sender.tag animate:YES]; }
- (void)updateAutoStartVisibility:(BOOL)animate {
    BOOL hide = ![self.draft[kCompletion] isEqualToString:kBanner];
    if (self.autoStartGroup.hidden == hide) return;
    self.autoStartGroup.hidden = hide;
    if (self.currentPane == 0) [self resizeSettings:animate];
}

#pragma mark Settings: showing and syncing

- (void)syncSettingsUI {
    NSDictionary *d = self.draft ?: [self currentValues];
    NSInteger f = [d[kFocus] integerValue], b = [d[kBreak] integerValue];
    if (!self.durationInvalid) { self.focusField.integerValue = f; self.breakField.integerValue = b; }
    self.focusStepper.integerValue = f; self.breakStepper.integerValue = b;
    NSDictionary<NSString *, NSSwitch *> *switches = @{kAutoBreak: self.autoBreakSwitch, kAutoFocus: self.autoFocusSwitch, kNotify: self.notifySwitch, kAmbient: self.ambientSwitch,
                                                       kPinned: self.pinSwitch, kMenuTime: self.menuTimeSwitch, kLogin: self.loginSwitch};
    [switches enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSSwitch *s, BOOL *stop) { s.state = [d[k] boolValue] ? NSControlStateValueOn : NSControlStateValueOff; }];
    for (NSMenuItem *i in self.completionPopup.itemArray) if ([i.representedObject isEqual:d[kCompletion]]) [self.completionPopup selectItem:i];
    for (NSMenuItem *i in self.soundPopup.itemArray) if ([i.representedObject isEqual:d[kSoundName]]) [self.soundPopup selectItem:i];
    self.previewButton.enabled = ![d[kSoundName] isEqualToString:@"none"];
    for (ThemeTile *t in self.themeTiles) { BOOL c = [t.theme.key isEqualToString:d[kTheme]]; if (t.chosen != c) { t.chosen = c; t.needsDisplay = YES; } }
    self.opacitySlider.doubleValue = [d[kOpacity] doubleValue];
    for (NSMenuItem *i in self.languagePopup.itemArray) if ([i.representedObject isEqual:d[kLanguage]]) [self.languagePopup selectItem:i];
    [self updateLanguageUI];
    [self updateAutoStartVisibility:NO];
    [self updateDurationNote]; [self updatePermissionUI]; [self updateLoginUI:nil]; [self updateSaveBar];
}

- (void)showSettings:(id)sender { [self showSettingsPane:self.currentPane < 0 ? 0 : self.currentPane focusDuration:NO]; }
- (void)showSettingsPane:(NSInteger)pane focusDuration:(BOOL)focusDuration {
    [self buildSettings];
    if (!self.settingsWindow.visible || !self.draft) { self.draft = [[self currentValues] mutableCopy]; self.durationInvalid = NO; self.showingError = NO; }
    [self syncSettingsUI];
    [self selectPane:pane animate:self.settingsWindow.visible];
    NSTextField *field = focusDuration ? (self.rest ? self.breakField : self.focusField) : nil;
    if (self.headless) { if (field) [self.settingsWindow makeFirstResponder:field]; return; }
    [self readAuthorization];
    [self activate]; [self.settingsWindow makeKeyAndOrderFront:nil];
    if (field) { [self.settingsWindow makeFirstResponder:field]; [field selectText:nil]; }
}

// The Save bar: what is saved, what is not, and whether Save can run.
- (void)updateSaveBar {
    if (!self.statusLabel) return;
    BOOL dirty = [self settingsDirty], invalid = self.durationInvalid;
    NSString *text, *sym; NSColor *color;
    if (invalid) { text = T(@"时长无效，请输入 1–180", @"Fix the length (1 to 180)"); sym = @"exclamationmark.triangle.fill"; color = NSColor.systemRedColor; }
    else if (dirty) {
        NSUInteger n = [self dirtyKeys].count;
        text = [NSString stringWithFormat:T(@"%lu 项未保存的更改", n == 1 ? @"%lu unsaved change" : @"%lu unsaved changes"), (unsigned long)n];
        sym = @"circle.fill"; color = NSColor.systemOrangeColor;
    } else if (self.lastSaved) { text = [NSString stringWithFormat:T(@"已保存 · %@", @"Saved · %@"), self.lastSaved]; sym = @"checkmark.circle.fill"; color = NSColor.systemGreenColor; }
    else { text = T(@"所有设置已保存", @"All settings saved"); sym = @"checkmark.circle"; color = NSColor.secondaryLabelColor; }
    setText(self.statusLabel, text);
    self.statusLabel.textColor = invalid || dirty ? NSColor.labelColor : NSColor.secondaryLabelColor;
    NSImage *img = symbol(sym, dirty && !invalid ? 8 : 13, nil); self.statusIcon.image = img; self.statusIcon.contentTintColor = color;
    self.statusIcon.imageScaling = NSImageScaleNone;
    self.saveButton.enabled = dirty && !invalid;
    self.revertButton.enabled = dirty || invalid;
    self.restoreButton.enabled = YES;
    self.settingsWindow.documentEdited = dirty;   // The close button shows the unsaved dot.
}

#pragma mark Settings: controls

- (void)switchChanged:(NSSwitch *)sender { [self setDraftValue:@(sender.state == NSControlStateValueOn) forKey:sender.identifier]; }
- (void)completionChosen:(NSPopUpButton *)sender { [self setDraftValue:sender.selectedItem.representedObject forKey:kCompletion]; }
- (void)soundChosen:(NSPopUpButton *)sender {
    NSString *name = sender.selectedItem.representedObject;
    [self setDraftValue:name forKey:kSoundName];
    self.previewButton.enabled = ![name isEqualToString:@"none"];
    [self previewSound:nil];   // Hear the choice right away.
}
- (void)previewSound:(id)sender {
    NSString *name = self.draft[kSoundName] ?: self.soundName;
    [self.alertLog addObject:[@"preview=" stringByAppendingString:name]];
    [self playSound:name];
}
- (void)themeChosen:(ThemeTile *)sender {
    for (ThemeTile *t in self.themeTiles) { t.chosen = t == sender; t.needsDisplay = YES; }
    [self setDraftValue:sender.theme.key forKey:kTheme];
}
- (void)opacityChanged:(NSSlider *)sender { [self setDraftValue:@(round(boundedDouble(sender.doubleValue, .1, .9, .45) * 100) / 100) forKey:kOpacity]; }

- (void)updateDurationNote {
    if (self.showingError || !self.durationNote) return;
    self.durationNote.textColor = NSColor.secondaryLabelColor;
    NSString *s;
    if (self.running) s = T(@"计时进行中：新时长从下一段开始生效。", @"A timer is running. A new length applies from the next phase.");
    else if (self.paused) s = T(@"计时已暂停：保存后，这一段按新时长继续（已用时间保留）。", @"Paused: after you save, this phase continues with the new length (time used is kept).");
    else s = T(@"可设置 1–180 分钟。", @"Use 1 to 180 minutes.");
    setText(self.durationNote, s);
}
- (void)showDurationError:(NSString *)message {
    self.showingError = YES; NSInteger generation = ++self.messageGeneration;
    self.durationNote.textColor = NSColor.systemRedColor; self.durationNote.stringValue = message;
    NSAccessibilityPostNotificationWithUserInfo(self.durationNote, NSAccessibilityAnnouncementRequestedNotification, @{NSAccessibilityAnnouncementKey: message});
    if (self.headless) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.messageGeneration == generation) { self.showingError = NO; [self updateDurationNote]; }
    });
}
- (void)clearDurationError { if (self.showingError) { self.showingError = NO; self.messageGeneration++; [self updateDurationNote]; } }

// While typing: a valid value goes into the draft at once; an invalid one blocks Save and is explained.
- (void)controlTextDidChange:(NSNotification *)n {
    NSTextField *field = n.object; if (field != self.focusField && field != self.breakField) return;
    NSInteger value = parseMinutes(field.stringValue);
    self.durationInvalid = value < 0;
    if (value >= 0) { [self clearDurationError]; [self setDraftValue:@(value) forKey:field.tag == 1 ? kBreak : kFocus]; (field.tag == 1 ? self.breakStepper : self.focusStepper).integerValue = value; }
    else [self updateSaveBar];
}
// End of editing: an invalid entry goes back to the last valid value, with a message.
- (void)durationEdited:(NSTextField *)field {
    BOOL isBreak = field.tag == 1;
    NSString *typed = field.stringValue;
    NSInteger value = parseMinutes(typed);
    NSString *key = isBreak ? kBreak : kFocus;
    if (value < 0) {
        self.durationInvalid = NO;
        field.integerValue = [(self.draft ?: [self currentValues])[key] integerValue];
        NSString *shown = typed.length > 8 ? [[typed substringToIndex:8] stringByAppendingString:@"…"] : typed;
        [self showDurationError:[NSString stringWithFormat:T(@"“%@”无效，请输入 1–180 的整数。", @"“%@” is not valid. Use 1 to 180."), shown]];
        [self updateSaveBar];
        return;
    }
    self.durationInvalid = NO; [self clearDurationError];
    field.integerValue = value; (isBreak ? self.breakStepper : self.focusStepper).integerValue = value;
    [self setDraftValue:@(value) forKey:key];
}
- (void)durationEditedText:(NSString *)text rest:(BOOL)isBreak {   // Used by tests: type and leave the field.
    NSTextField *f = isBreak ? self.breakField : self.focusField; f.stringValue = text;
    [self controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f]];
    [self durationEdited:f];
}
- (void)stepDuration:(NSStepper *)sender {
    self.durationInvalid = NO; [self clearDurationError];
    (sender.tag == 1 ? self.breakField : self.focusField).integerValue = sender.integerValue;
    [self setDraftValue:@(sender.integerValue) forKey:sender.tag == 1 ? kBreak : kFocus];
}

- (void)restoreDefaults:(id)sender {
    self.draft = [[self defaultValues] mutableCopy]; self.durationInvalid = NO; [self clearDurationError];
    [self previewDraft]; [self syncSettingsUI];
}
- (void)revertSettings:(id)sender {
    self.draft = [[self currentValues] mutableCopy]; self.durationInvalid = NO; [self clearDurationError];
    [self clearPreview]; [self syncSettingsUI];
}

- (void)languageChosen:(NSPopUpButton *)sender { [self setDraftValue:sender.selectedItem.representedObject forKey:kLanguage]; [self updateLanguageUI]; }
static BOOL languageIsChinese(NSString *pref) { return [pref isEqualToString:@"zh"] ? YES : [pref isEqualToString:@"en"] ? NO : systemPrefersChinese(); }
// The app shows the saved language after it opens again; Relaunch Now does that at once (the timer keeps its state).
- (BOOL)languageNeedsRelaunch { return languageIsChinese(self.languagePref) != gChinese; }
- (void)updateLanguageUI {
    if (!self.languageNote) return;
    NSString *draftLang = (self.draft ?: [self currentValues])[kLanguage];
    BOOL pendingSave = ![draftLang isEqualToString:self.languagePref], relaunch = [self languageNeedsRelaunch];
    self.relaunchButton.hidden = !relaunch || pendingSave;
    setText(self.languageNote, pendingSave && languageIsChinese(draftLang) != gChinese ? T(@"保存后，重新打开专注卡片即可切换。", @"After you save, relaunch FocusCard to switch.")
                             : relaunch ? T(@"重新打开后使用新语言。计时不会中断。", @"Relaunch to use the new language. The timer keeps running.")
                                        : T(@"界面语言。", @"The language of the app."));
}
- (void)relaunch:(id)sender {
    [self.alertLog addObject:@"relaunch"];
    if (self.sandboxed) return;
    [self save]; [self.defaults synchronize];
    // A short helper waits until this instance has quit, then opens the app again. The new instance restores the timer.
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", @"while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"", @"relaunch",
                       [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier], NSBundle.mainBundle.bundlePath];
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) { setText(self.languageNote, [NSString stringWithFormat:T(@"无法重新打开：%@", @"Cannot relaunch: %@"), err.localizedDescription ?: @"?"]); return; }
    [NSApp terminate:nil];
}

#pragma mark Settings: saving

- (void)saveSettings:(id)sender { [self saveDraft]; }
- (BOOL)saveDraft {
    if (self.settingsWindow.visible) [self.settingsWindow makeFirstResponder:nil];   // Commit the field being edited.
    if (self.durationInvalid || !self.draft) { [self updateSaveBar]; return NO; }
    NSDictionary *d = self.draft.copy;
    NSInteger focus = boundedMinutes([d[kFocus] integerValue], self.focusMinutes), brk = boundedMinutes([d[kBreak] integerValue], self.breakMinutes);
    BOOL phaseChanged = self.rest ? brk != self.breakMinutes : focus != self.focusMinutes;
    BOOL wasNotifying = self.notifications;
    self.focusMinutes = focus; self.breakMinutes = brk;
    self.autoBreak = [d[kAutoBreak] boolValue]; self.autoFocus = [d[kAutoFocus] boolValue];
    self.notifications = [d[kNotify] boolValue]; self.soundName = validSound(d[kSoundName]);
    self.completionStyle = [d[kCompletion] isEqualToString:kBanner] ? kBanner : kOverlay;
    self.themeKey = themeNamed(d[kTheme]).key; self.ambient = [d[kAmbient] boolValue];
    self.languagePref = [@[@"zh", @"en"] containsObject:d[kLanguage]] ? d[kLanguage] : @"system";
    self.pinned = [d[kPinned] boolValue]; self.glassOpacity = boundedDouble([d[kOpacity] doubleValue], .1, .9, .45); self.showMenuTime = [d[kMenuTime] boolValue];
    self.panel.level = self.pinned ? NSFloatingWindowLevel : NSNormalWindowLevel - 1;
    if (self.notifications && !wasNotifying) [self ensureNotifications];
    NSString *loginError = nil;
    if ([d[kLogin] boolValue] != [self loginEnabled]) loginError = [self setLogin:[d[kLogin] boolValue]];
    if (phaseChanged) {
        double duration = [self durationForRest:self.rest];
        if (!self.started) { self.sessionDuration = duration; self.countdown = (Countdown){duration, 0}; }
        else if (self.paused) {   // Keep the time already used; a shorter length can leave 00:00 (Resume then finishes the phase).
            double used = MAX(0, self.sessionDuration - self.countdown.remaining);
            self.sessionDuration = duration; self.countdown = (Countdown){MAX(0, duration - used), 0};
        }   // Running: the new length applies from the next phase.
    }
    [self save];
    self.previewTheme = nil; self.previewOpacity = -1; self.previewAmbient = nil;
    [self applyThemeToCard];
    self.lastSaved = clockText(clockNow()); self.saveGeneration++;
    self.draft = [[self currentValues] mutableCopy];
    [self syncSettingsUI]; [self updateLoginUI:loginError];
    self.lastSeconds = -1; [self refreshForce:YES];
    NSString *said = T(@"设置已保存", @"Settings saved");
    NSAccessibilityPostNotificationWithUserInfo(self.statusLabel ?: NSApp, NSAccessibilityAnnouncementRequestedNotification, @{NSAccessibilityAnnouncementKey: said});
    if (!self.headless && !reduceMotion()) {   // A brief confirmation pulse on the status line.
        self.statusLabel.alphaValue = .2; self.statusIcon.alphaValue = .2;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = .35; self.statusLabel.animator.alphaValue = 1; self.statusIcon.animator.alphaValue = 1; }];
    }
    return YES;
}

- (BOOL)windowShouldClose:(NSWindow *)window {
    if (window != self.settingsWindow || (![self settingsDirty] && !self.durationInvalid) || self.headless) return YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = T(@"要保存对设置的更改吗？", @"Save changes to your settings?");
    alert.informativeText = T(@"如果不保存，你的更改将丢失。", @"If you don’t save, your changes will be lost.");
    [alert addButtonWithTitle:T(@"保存", @"Save")]; [alert addButtonWithTitle:T(@"取消", @"Cancel")]; [alert addButtonWithTitle:T(@"不保存", @"Don’t Save")];
    alert.buttons[2].keyEquivalent = @"d"; alert.buttons[2].keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse r) {
        if (r == NSAlertFirstButtonReturn) { if ([self saveDraft]) [window close]; }
        else if (r == NSAlertThirdButtonReturn) { [self revertSettings:nil]; [window close]; }
    }];
    return NO;
}
- (void)windowWillClose:(NSNotification *)n {
    if (n.object != self.settingsWindow) return;
    self.draft = nil; self.durationInvalid = NO; self.showingError = NO; [self clearPreview];
}

#pragma mark Settings: permission and login

- (void)updatePermissionUI {
    if (!self.permissionLabel) return;
    BOOL on = self.draft ? [self.draft[kNotify] boolValue] : self.notifications;
    self.permissionButton.enabled = on;
    if (!on) { setText(self.permissionLabel, T(@"关闭。仍会显示全屏提示和播放提示音。", @"Off. The prompt and sound still work.")); self.permissionButton.title = T(@"允许通知…", @"Allow Notifications…"); return; }
    switch (self.authorization) {
        case UNAuthorizationStatusAuthorized: case UNAuthorizationStatusProvisional:
            setText(self.permissionLabel, T(@"macOS 已允许通知。", @"macOS allows notifications."));
            self.permissionButton.title = T(@"发送测试通知", @"Send Test Notification"); break;
        case UNAuthorizationStatusDenied:
            setText(self.permissionLabel, T(@"macOS 已关闭本应用的通知。", @"macOS blocks notifications for this app."));
            self.permissionButton.title = T(@"打开通知设置…", @"Open Notification Settings…"); break;
        default:
            setText(self.permissionLabel, T(@"需要你允许通知。", @"Notifications need your permission."));
            self.permissionButton.title = T(@"允许通知…", @"Allow Notifications…"); break;
    }
}
- (void)permissionAction:(id)sender {
    if (self.sandboxed) return;
    if (self.authorization == UNAuthorizationStatusDenied) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Notifications-Settings.extension"]];
    } else if (self.authorization == UNAuthorizationStatusAuthorized || self.authorization == UNAuthorizationStatusProvisional) {
        NSString *sound = self.soundName; BOOL notify = self.notifications; self.soundName = @"none"; self.notifications = YES;
        [self notifyTitle:T(@"通知已就绪", @"Notifications are ready") body:T(@"专注或休息结束时，你会在这里收到提醒。", @"You will get an alert here when a phase ends.")];
        self.soundName = sound; self.notifications = notify;
        setText(self.permissionLabel, T(@"已发送。如果没有看到，请检查 macOS 的专注模式。", @"Sent. If you do not see it, check macOS Focus settings."));
    } else {
        [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                                                            completionHandler:^(BOOL granted, NSError *error) { [self readAuthorization]; }];
    }
}
- (void)updateLoginUI:(NSString *)error {
    if (!self.loginNote) return;
    SMAppServiceStatus status = self.sandboxed ? SMAppServiceStatusNotRegistered : SMAppService.mainAppService.status;
    self.loginNote.textColor = error ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    NSString *hint = status == SMAppServiceStatusRequiresApproval
        ? T(@"请在“系统设置 › 通用 › 登录项”中允许专注卡片。", @"Allow FocusCard in System Settings › General › Login Items.")
        : T(@"在你登录 Mac 后自动打开。", @"Opens automatically after you log in.");
    setText(self.loginNote, error ?: hint);
}
- (NSString *)setLogin:(BOOL)on {
    if (self.sandboxed) { self.fakeLogin = on; return nil; }
    SMAppService *svc = SMAppService.mainAppService; NSError *err = nil;
    BOOL ok = on ? [svc registerAndReturnError:&err] : [svc unregisterAndReturnError:&err];
    if (svc.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
    return ok ? nil : [NSString stringWithFormat:T(@"无法更改登录项：%@", @"Cannot change the login item: %@"), err.localizedDescription ?: @"?"];
}

#pragma mark Lifecycle

- (void)startHeadless:(NSUserDefaults *)defaults {   // Used by tests and screenshot rendering.
    self.headless = YES; self.sandboxed = YES; self.defaults = defaults; [self loadState];
    [self buildCard]; [self buildStatusMenu]; [self buildSettings]; [self syncSettingsUI];
    [self applyThemeToCard]; [self refreshForce:YES];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.defaults = NSUserDefaults.standardUserDefaults;
    [self loadState];
    [UNUserNotificationCenter currentNotificationCenter].delegate = self;
    [self buildCard]; [self buildMainMenu]; [self buildStatusMenu]; [self readAuthorization];
    [self refreshForce:YES]; [self updateTicker];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(clockChanged) name:NSWorkspaceDidWakeNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(motionSettingsChanged) name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clockChanged) name:NSSystemClockDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clockChanged) name:NSCalendarDayChangedNotification object:nil];
    if (self.cardVisible) [self showCard:nil];
}
- (void)motionSettingsChanged { [self applyThemeToCard]; }   // Reduce Motion, Reduce Transparency or Increase Contrast changed.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible { [self showCard:nil]; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification { [self save]; }
@end

#pragma mark - Self-test

static int gPass = 0, gFail = 0;
static NSMutableArray *gResults;
static void check(NSString *tid, NSString *desc, BOOL ok, NSString *detail) {
    if (ok) gPass++; else gFail++;
    printf("%s %s %s%s%s\n", ok ? "PASS" : "FAIL", tid.UTF8String, desc.UTF8String, detail.length ? " :: " : "", detail.length ? detail.UTF8String : "");
    [gResults addObject:@{@"id": tid, @"description": desc, @"status": ok ? @"PASS" : @"FAIL", @"detail": detail ?: @""}];
}
#define CHECK(tid, desc, cond, detail) check(tid, desc, (cond), detail)

static NSString *const kSuite = @"focuscard.selftest";
static NSUserDefaults *freshSuite(void) {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:kSuite];
    return [[NSUserDefaults alloc] initWithSuiteName:kSuite];
}
static AppDelegate *makeApp(NSUserDefaults *d) { AppDelegate *a = [AppDelegate new]; [a startHeadless:d]; return a; }
static BOOL inside(NSView *v, NSView *container) { return NSContainsRect(NSInsetRect(container.bounds, -.5, -.5), [container convertRect:v.bounds fromView:v]); }
static CGFloat textWidth(NSTextField *f) { return [f.stringValue sizeWithAttributes:@{NSFontAttributeName: f.font}].width; }
static CGFloat titleWidth(NSButton *b) { return [b.title sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]}].width; }
static NSString *S(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static NSString *S(NSString *fmt, ...) { va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap); return s; }
// Changes one setting the way a person does: open Settings, change the control's draft value, press Save.
static BOOL saveSetting(AppDelegate *a, NSString *key, id value) {
    [a showSettingsPane:a.currentPane < 0 ? 0 : a.currentPane focusDuration:NO]; [a setDraftValue:value forKey:key]; return [a saveDraft];
}
static double luminance(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    double (^lin)(double) = ^double(double v) { return v <= .03928 ? v / 12.92 : pow((v + .055) / 1.055, 2.4); };
    return .2126 * lin(s.redComponent) + .7152 * lin(s.greenComponent) + .0722 * lin(s.blueComponent);
}
static double contrast(NSColor *a, NSColor *b) { double x = luminance(a), y = luminance(b); return (MAX(x, y) + .05) / (MIN(x, y) + .05); }
// Paints the foreground at its alpha over the opaque background, as the screen shows it.
static NSColor *over(NSColor *fg, NSColor *bg) {
    NSColor *f = [fg colorUsingColorSpace:NSColorSpace.sRGBColorSpace], *b = [bg colorUsingColorSpace:NSColorSpace.sRGBColorSpace]; CGFloat a = f.alphaComponent;
    return rgb(f.redComponent * a + b.redComponent * (1 - a), f.greenComponent * a + b.greenComponent * (1 - a), f.blueComponent * a + b.blueComponent * (1 - a), 1);
}
static NSArray<NSTextField *> *cardTexts(AppDelegate *a) { return @[a.phaseLabel, a.roundsLabel, a.timeLabel, a.stateLabel]; }

static void layoutChecks(AppDelegate *a, NSString *lang) {
    NSArray *controls = @[a.phaseLabel, a.roundsLabel, a.compactButton, a.settingsButton, a.hideButton, a.ring, a.stateLabel, a.resetButton, a.startButton, a.skipButton];
    BOOL allInside = YES, noOverlap = YES; NSMutableString *detail = [NSMutableString string];
    for (NSView *v in controls) if (!inside(v, a.card)) { allInside = NO; [detail appendFormat:@"%@ outside; ", v.className]; }
    NSArray *solid = @[a.phaseIcon, a.phaseLabel, a.roundsLabel, a.compactButton, a.settingsButton, a.hideButton, a.resetButton, a.startButton, a.skipButton, a.stateLabel, a.timeLabel];
    for (NSUInteger i = 0; i < solid.count; i++) for (NSUInteger j = i + 1; j < solid.count; j++)
        if (NSIntersectsRect([solid[i] frame], [solid[j] frame])) { noOverlap = NO; [detail appendFormat:@"%lu∩%lu; ", (unsigned long)i, (unsigned long)j]; }
    CHECK(S(@"UI-L01-%@", lang), @"Card controls stay inside card bounds", allInside, detail);
    CHECK(S(@"UI-L02-%@", lang), @"Card controls and labels do not overlap", noOverlap, detail);
    NSArray *buttons = @[a.resetButton, a.startButton, a.skipButton, a.compactButton, a.settingsButton, a.hideButton];
    BOOL big = YES; for (NSButton *b in buttons) if (b.frame.size.width < 28 || b.frame.size.height < 28) big = NO;
    CHECK(S(@"UI-L03-%@", lang), @"Card hit targets are at least 28x28 pt", big, @"");
}

static void selfTest(NSString *resultsPath) {
    gResults = [NSMutableArray array];
    [NSApplication sharedApplication];
    // --- Timer model -----------------------------------------------------------------
    Countdown c = {1500, 0};
    CHECK(@"TM-01", @"Idle countdown reports full duration", secondsLeft(c, 1000) == 1500, @"");
    startTimer(&c, 1000); CHECK(@"TM-02", @"Running countdown subtracts elapsed time", secondsLeft(c, 1061) == 1439, @"");
    startTimer(&c, 1061); CHECK(@"TM-03", @"A second start does not move the deadline", c.deadline == 2500, @"");
    pauseTimer(&c, 1061.5); CHECK(@"TM-04", @"Pause stores remaining time and stops", secondsLeft(c, 2000) == 1439 && c.deadline == 0, @"");
    startTimer(&c, 2000); CHECK(@"TM-05", @"Resume continues from the stored time", secondsLeft(c, 2001) == 1438, @"");
    CHECK(@"TM-06", @"Finish fires once", finishTimer(&c, 4000) && secondsLeft(c, 4000) == 0 && !finishTimer(&c, 4001), @"");
    Countdown z = {0, 0}; startTimer(&z, 10); CHECK(@"TM-07", @"Start with zero remaining does nothing", z.deadline == 0, @"");
    Countdown f = {300, 0}; startTimer(&f, 0); CHECK(@"TM-08", @"Partial seconds round up (0.2 s shows 1 s)", secondsLeft(f, 299.8) == 1, @"");
    CHECK(@"TM-09", @"Minute bounds accept 1 and 180 only", boundedMinutes(0, 25) == 25 && boundedMinutes(181, 5) == 5 && boundedMinutes(1, 9) == 1 && boundedMinutes(180, 9) == 180 && boundedMinutes(-5, 7) == 7, @"");
    CHECK(@"TM-10", @"Time format covers 0 s to 180 min", [timeString(0) isEqualToString:@"00:00"] && [timeString(59) isEqualToString:@"00:59"] && [timeString(65) isEqualToString:@"01:05"] && [timeString(3599) isEqualToString:@"59:59"] && [timeString(10800) isEqualToString:@"180:00"], @"");
    CHECK(@"TM-11", @"Duration parser accepts valid input", parseMinutes(@"45") == 45 && parseMinutes(@" 30 ") == 30 && parseMinutes(@"１８０") == 180 && parseMinutes(@"1") == 1, S(@"%ld", (long)parseMinutes(@"１８０")));
    CHECK(@"TM-12", @"Duration parser rejects invalid input", parseMinutes(@"0") < 0 && parseMinutes(@"181") < 0 && parseMinutes(@"abc") < 0 && parseMinutes(@"") < 0 && parseMinutes(@"12.5") < 0 && parseMinutes(@"-3") < 0 && parseMinutes(@"1e2") < 0 && parseMinutes(@"99999999999999999999") < 0, @"");

    // --- Defaults and idle UI -----------------------------------------------------------
    gClockOffset = 0;
    NSUserDefaults *d = freshSuite();
    AppDelegate *a = makeApp(d);
    CHECK(@"ST-01", @"Fresh install uses documented defaults (overlay prompt, Glass sound, Aurora theme, ambient motion on)",
          a.focusMinutes == 25 && a.breakMinutes == 5 && a.autoBreak && !a.autoFocus && a.notifications && [a.soundName isEqualToString:@"Glass"] && [a.completionStyle isEqualToString:kOverlay]
          && [a.themeKey isEqualToString:@"aurora"] && a.ambient && !a.pinned && a.showMenuTime && fabs(a.glassOpacity - .45) < .001, @"");
    CHECK(@"ST-02", @"Idle card shows 25:00, Start Focus, Reset disabled", [a.timeLabel.stringValue isEqualToString:@"25:00"] && [a.startButton.title isEqualToString:T(@"开始专注", @"Start Focus")] && !a.resetButton.enabled, a.startButton.title);
    CHECK(@"ST-03", @"Idle menu bar shows the icon only", a.statusTitle.length == 0, a.statusTitle);
    CHECK(@"ST-04", @"Idle state text is shown", [a.stateLabel.stringValue isEqualToString:T(@"准备开始", @"Ready when you are")], a.stateLabel.stringValue);

    // --- Header: today's rounds next to the phase; no footer ------------------------------
    CHECK(@"HD-01", @"Header shows today's rounds right after the phase name", [a.roundsLabel.stringValue isEqualToString:T(@"今日 0 轮", @"0 today")]
          && NSMinX(a.roundsLabel.frame) > NSMaxX(a.phaseLabel.frame) && NSMinX(a.roundsLabel.frame) - NSMaxX(a.phaseLabel.frame) < 12
          && fabs(NSMidY(a.roundsLabel.frame) - NSMidY(a.phaseLabel.frame)) < 3, S(@"%@ %@ %@", a.roundsLabel.stringValue, NSStringFromRect(a.phaseLabel.frame), NSStringFromRect(a.roundsLabel.frame)));
    NSInteger textFields = 0; for (NSView *v in a.card.subviews) if ([v isKindOfClass:NSTextField.class]) textFields++;
    CHECK(@"HD-02", @"The card footer is gone: four texts only (phase, rounds, time, state)", textFields == 4, S(@"%ld", (long)textFields));
    a.statsSessions = 99; [a refreshForce:YES];
    CHECK(@"HD-03", @"Rounds label fits up to 99 rounds", textWidth(a.roundsLabel) <= a.roundsLabel.frame.size.width && !NSIntersectsRect(a.roundsLabel.frame, a.compactButton.frame), S(@"%.0f/%.0f", textWidth(a.roundsLabel), a.roundsLabel.frame.size.width));
    a.statsSessions = 0; [a refreshForce:YES];
    {
        NSAttributedString *ps = a.phaseLabel.attributedStringValue; NSRange r;
        NSTextAttachment *att = ps.length ? [ps attribute:NSAttachmentAttributeName atIndex:0 effectiveRange:&r] : nil;
        NSImage *raw = phaseSymbol(NO, 12); NSRect al = raw.alignmentRect; CGFloat k = att.bounds.size.height / raw.size.height;
        CGFloat iconMid = att.bounds.origin.y + NSMidY(al) * k, textMid = glyphMidY(T(@"专注", @"Focus"), a.phaseLabel.font);
        NSTextAttachment *gapAtt = ps.length > 1 ? [ps attribute:NSAttachmentAttributeName atIndex:1 effectiveRange:NULL] : nil;
        CHECK(@"HD-05", @"The phase icon's visible center matches the text's visible center (±0.5 pt), with a 6 pt gap", att && fabs(iconMid - textMid) <= .5 && gapAtt.bounds.size.width == 6 && a.phaseIcon.hidden
              , S(@"icon=%.2f text=%.2f", iconMid, textMid));
        [a skip:nil]; NSTextAttachment *att2 = [a.phaseLabel.attributedStringValue attribute:NSAttachmentAttributeName atIndex:0 effectiveRange:&r];
        CHECK(@"HD-06", @"The icon changes with the phase (hourglass → cup)", att2 && att2.image != att.image && [a.phaseLabel.stringValue containsString:T(@"休息", @"Break")], a.phaseLabel.stringValue);
        [a skip:nil];
        CHECK(@"SF-01", @"The theme background layers fill the card", NSEqualRects(a.surface.gradient.frame, a.surface.bounds) && NSEqualRects(a.surface.fx.frame, a.surface.bounds) && a.surface.bounds.size.width == kCardW,
              NSStringFromRect(a.surface.gradient.frame));
    }

    // --- Start / pause / resume / reset ----------------------------------------------------
    [a toggle:nil];
    CHECK(@"ST-05", @"Start runs the timer and shows Pause", a.running && [a.startButton.title isEqualToString:T(@"暂停", @"Pause")] && a.resetButton.enabled, @"");
    CHECK(@"ST-06", @"Running menu bar shows the countdown", [a.statusTitle isEqualToString:@"25:00"] && !a.statusDimmed, a.statusTitle);
    gClockOffset += 10; [a refresh];
    CHECK(@"ST-07", @"Card and menu bar advance together", [a.timeLabel.stringValue isEqualToString:@"24:50"] && [a.statusTitle isEqualToString:@"24:50"], a.timeLabel.stringValue);
    CHECK(@"ST-08", @"Ring progress follows elapsed time", fabs(a.ring.progress - 10.0 / 1500) < .001, S(@"%f", a.ring.progress));
    CHECK(@"DC-04a", @"While running, the time is not editable (no hand pointer)", NSIsEmptyRect(a.card.editableRect), NSStringFromRect(a.card.editableRect));
    CHECK(@"DC-01", @"Double-click on the time while running does nothing", ![a handleDoubleClickAt:NSMakePoint(NSMidX(a.timeLabel.frame), NSMidY(a.timeLabel.frame))] && a.running, @"");
    [a toggle:nil];
    CHECK(@"ST-09", @"Pause stops the timer and shows Resume", a.paused && [a.startButton.title isEqualToString:T(@"继续", @"Resume")] && a.statusDimmed && a.ring.dimmed, @"");
    gClockOffset += 100; [a refresh];
    CHECK(@"ST-10", @"Paused time does not advance", [a.timeLabel.stringValue isEqualToString:@"24:50"], a.timeLabel.stringValue);
    CHECK(@"ST-11", @"Paused state text tells how to change the length", [a.stateLabel.stringValue isEqualToString:T(@"已暂停 · 双击时间可调整时长", @"Paused · double-click to edit")], a.stateLabel.stringValue);
    CHECK(@"DC-04", @"While paused, the time has a hand pointer area", NSContainsRect(a.card.editableRect, a.timeLabel.frame), NSStringFromRect(a.card.editableRect));
    [a toggle:nil]; gClockOffset += 5; [a refresh];
    CHECK(@"ST-12", @"Resume continues from the paused time", [a.timeLabel.stringValue isEqualToString:@"24:45"], a.timeLabel.stringValue);
    [a reset:nil];
    CHECK(@"ST-13", @"Reset restores full duration and idle state", !a.started && [a.timeLabel.stringValue isEqualToString:@"25:00"] && !a.resetButton.enabled && a.statusTitle.length == 0, @"");

    // --- Skip ---------------------------------------------------------------------------
    NSInteger before = a.statsSessions;
    [a skip:nil];
    CHECK(@"ST-14", @"Skip from focus goes to an idle 05:00 break", a.rest && !a.started && [a.timeLabel.stringValue isEqualToString:@"05:00"] && [a.startButton.title isEqualToString:T(@"开始休息", @"Start Break")], a.timeLabel.stringValue);
    CHECK(@"ST-15", @"Skip does not count a session", a.statsSessions == before, @"");
    [a skip:nil];
    CHECK(@"ST-16", @"Skip from break goes back to focus", !a.rest && [a.timeLabel.stringValue isEqualToString:@"25:00"], @"");
    [a toggle:nil]; gClockOffset += 30; [a skip:nil];
    CHECK(@"ST-17", @"Skip while running discards the phase and stops", a.rest && !a.started && !a.running, @"");
    [a skip:nil];

    // --- Completion: full-screen prompt (default) ------------------------------------------
    [a.alertLog removeAllObjects];
    [a toggle:nil]; gClockOffset += 1500.5; [a refresh];
    CHECK(@"ST-18", @"Focus completion shows 'Time to Take a Break' and waits (auto break is ignored)", a.rest && !a.started && a.autoBreak && a.overlay.visible
          && [a.overlay.title isEqualToString:T(@"该休息了", @"Time to Take a Break")], S(@"rest=%d started=%d overlay=%d", a.rest, a.started, a.overlay.visible));
    CHECK(@"ST-19", @"Focus completion counts one session and 25 minutes", a.statsSessions == 1 && fabs(a.statsFocusSeconds - 1500) < 1, S(@"%ld", (long)a.statsSessions));
    CHECK(@"ST-20", @"Focus completion sends exactly one alert with the chosen sound", a.alertLog.count == 1 && [a.alertLog.firstObject hasPrefix:T(@"专注完成", @"Focus complete")] && [a.alertLog.firstObject containsString:@"sound=Glass"], a.alertLog.firstObject);
    CHECK(@"HD-04", @"The header count goes up at once", [a.roundsLabel.stringValue isEqualToString:T(@"今日 1 轮", @"1 today")], a.roundsLabel.stringValue);
    [a refresh]; [a refresh];
    CHECK(@"ST-21", @"Repeated refresh does not complete again", a.statsSessions == 1 && a.alertLog.count == 1, @"");
    CHECK(@"OV-01", @"Prompt offers 'Start Break · 5 min' and 'Not Now'", [a.overlay.primaryTitle isEqualToString:T(@"开始休息 · 5 分钟", @"Start Break · 5 min")] && [a.overlay.secondaryTitle isEqualToString:T(@"稍后", @"Not Now")], a.overlay.primaryTitle);
    [a overlayPrimary:nil];
    CHECK(@"OV-02", @"The prompt's main button starts the break and closes the prompt", a.rest && a.running && !a.overlay.visible && [a secondsRemaining] == 300, S(@"%ld", (long)[a secondsRemaining]));
    gClockOffset += 301; [a refresh];
    CHECK(@"ST-22", @"Break completion shows 'Ready to Focus?' and waits", !a.rest && !a.started && a.overlay.visible && [a.overlay.title isEqualToString:T(@"准备好专注了吗？", @"Ready to Focus?")] && [a.timeLabel.stringValue isEqualToString:@"25:00"], a.overlay.title);
    CHECK(@"ST-23", @"Break completion shows the completion text and alert", [a.stateLabel.stringValue isEqualToString:T(@"休息结束，准备下一轮专注", @"Break over. Ready to focus?")] && a.alertLog.count == 2, a.stateLabel.stringValue);
    [a overlaySecondary:nil];
    CHECK(@"OV-03", @"'Not Now' closes the prompt; focus stays ready on the card", !a.overlay.visible && !a.started && !a.rest && [a.startButton.title isEqualToString:T(@"开始专注", @"Start Focus")], @"");
    [a toggle:nil]; gClockOffset += 1500.5; [a refresh]; [a toggle:nil];
    CHECK(@"OV-04", @"Start on the card while the prompt shows closes it and starts the next phase", !a.overlay.visible && a.rest && a.running, @"");
    [a reset:nil]; [a skip:nil];
    [a toggle:nil]; gClockOffset += 1500.5; [a refresh]; [a skip:nil];
    CHECK(@"OV-05", @"Skip while the prompt shows closes it", !a.overlay.visible && !a.rest && !a.started, @"");
    [a toggle:nil]; gClockOffset += 1500.5; [a refresh]; [a reset:nil];
    CHECK(@"OV-06", @"Reset while the prompt shows closes it", !a.overlay.visible && !a.started, @"");
    [a skip:nil];
    [a.alertLog removeAllObjects]; NSInteger sessions = a.statsSessions; NSString *dayBefore = a.statsDay;
    [a toggle:nil]; gClockOffset += 1500 + 7200; [a refresh];
    NSInteger lateSessions = [dayKey(clockNow() - 7200) isEqualToString:dayKey(clockNow())] ? ([dayKey(clockNow() - 7200) isEqualToString:dayBefore] ? sessions + 1 : 1) : 0;
    CHECK(@"OV-07", @"Late completion (Mac asleep) shows the prompt silently with the end time", a.overlay.visible && a.alertLog.count == 0 && [a.overlay.subtitle containsString:@":"] && a.statsSessions == lateSessions, a.overlay.subtitle);
    [a overlaySecondary:nil]; [a skip:nil];
    CHECK(@"OV-08", @"The prompt's main button acts once (a second press does not restart)", ({ [a toggle:nil]; gClockOffset += 1500.5; [a refresh]; [a overlayPrimary:nil]; gClockOffset += 3; [a refresh]; [a overlayPrimary:nil]; [a secondsRemaining] == 297; }), S(@"%ld", (long)[a secondsRemaining]));
    [a reset:nil]; [a skip:nil];

    // --- Completion: notification only -------------------------------------------------
    CHECK(@"OV-09", @"'Notification only' style is saved", saveSetting(a, kCompletion, kBanner) && [a.completionStyle isEqualToString:kBanner] && [[d stringForKey:kCompletion] isEqualToString:kBanner], @"");
    [a.alertLog removeAllObjects];
    [a toggle:nil]; gClockOffset += 1500.5; [a refresh];
    CHECK(@"ST-24", @"Notification only: focus completion starts the break (auto break on), no prompt", a.rest && a.running && !a.overlay.visible && [a secondsRemaining] == 300, S(@"%ld", (long)[a secondsRemaining]));
    gClockOffset += 301; [a refresh];
    CHECK(@"ST-25", @"Notification only: break completion waits (auto focus off)", !a.rest && !a.started && !a.overlay.visible, @"");
    saveSetting(a, kAutoFocus, @YES); [a skip:nil]; [a toggle:nil]; gClockOffset += 300.2; [a refresh];
    CHECK(@"ST-26", @"Notification only: break completion starts focus when auto focus is on", !a.rest && a.running, @"");
    saveSetting(a, kAutoFocus, @NO); [a reset:nil];
    saveSetting(a, kAutoBreak, @NO); [a toggle:nil]; gClockOffset += 1501; [a refresh];
    CHECK(@"ST-27", @"Notification only: focus completion waits when auto break is off", a.rest && !a.started, @"");
    saveSetting(a, kAutoBreak, @YES); [a skip:nil];
    [a.alertLog removeAllObjects]; sessions = a.statsSessions; dayBefore = a.statsDay;
    [a toggle:nil]; gClockOffset += 1500 + 7200; [a refresh];
    lateSessions = [dayKey(clockNow() - 7200) isEqualToString:dayKey(clockNow())] ? ([dayKey(clockNow() - 7200) isEqualToString:dayBefore] ? sessions + 1 : 1) : 0;
    CHECK(@"ST-28", @"Late completion is silent and does not auto start", a.alertLog.count == 0 && a.rest && !a.started && a.statsSessions == lateSessions && [a.stateLabel.stringValue containsString:@":"], a.stateLabel.stringValue);
    [a skip:nil];
    [a toggle:nil]; gClockOffset += 1500.5; [a toggle:nil];
    CHECK(@"ST-29", @"Start/Pause right after expiry acts on the next phase", a.rest && a.started && [a secondsRemaining] > 0, S(@"rest=%d started=%d s=%ld", a.rest, a.started, (long)[a secondsRemaining]));
    [a skip:nil];
    saveSetting(a, kNotify, @NO); saveSetting(a, kSoundName, @"none");
    [a.alertLog removeAllObjects]; [a toggle:nil]; gClockOffset += 1500.5; [a refresh];
    CHECK(@"ST-30", @"Alert respects the notification setting and 'None' sound", a.alertLog.count == 1 && [a.alertLog.firstObject hasSuffix:@"sound=none|notify=0"], a.alertLog.firstObject);
    saveSetting(a, kNotify, @YES); saveSetting(a, kSoundName, @"Glass"); saveSetting(a, kCompletion, kOverlay); [a reset:nil]; if (a.rest) [a skip:nil];

    // --- Sounds ---------------------------------------------------------------------------
    {
        NSMutableString *missing = [NSMutableString string];
        for (NSArray *s in allSounds()) if (![s[0] isEqualToString:@"none"] && ![NSSound soundNamed:s[0]]) [missing appendFormat:@"%@ ", s[0]];
        CHECK(@"SO-01", @"Eight sound choices; every system sound is present on this Mac", allSounds().count == 8 && missing.length == 0 && a.soundPopup.numberOfItems == 8, missing);
        [a showSettingsPane:1 focusDuration:NO];
        [a.soundPopup selectItemAtIndex:2]; [a soundChosen:a.soundPopup];
        CHECK(@"SO-02", @"Choosing a sound previews it at once and changes only the draft", [a.alertLog.lastObject isEqualToString:@"preview=Hero"] && [a.soundName isEqualToString:@"Glass"] && ![[d stringForKey:kSoundName] isEqualToString:@"Hero"], a.alertLog.lastObject);
        [a previewSound:a.previewButton];
        CHECK(@"SO-03", @"The preview button plays the chosen sound", [a.alertLog.lastObject isEqualToString:@"preview=Hero"] && a.previewButton.enabled, a.alertLog.lastObject);
        [a saveDraft];
        CHECK(@"SO-04", @"Save stores the sound", [a.soundName isEqualToString:@"Hero"] && [[d stringForKey:kSoundName] isEqualToString:@"Hero"], [d stringForKey:kSoundName]);
        [a.alertLog removeAllObjects]; [a toggle:nil]; gClockOffset += 1500.5; [a refresh];
        CHECK(@"SO-05", @"A completion plays the chosen sound", [a.alertLog.firstObject containsString:@"sound=Hero"], a.alertLog.firstObject);
        [a overlaySecondary:nil]; [a skip:nil];
        [a.soundPopup selectItemAtIndex:0]; [a soundChosen:a.soundPopup];
        CHECK(@"SO-06", @"'None' disables the preview button", !a.previewButton.enabled, @"");
        [a revertSettings:nil];
        NSUserDefaults *m1 = freshSuite(); [m1 setBool:NO forKey:kSound]; AppDelegate *s1 = makeApp(m1);
        NSUserDefaults *m2 = freshSuite(); [m2 setBool:YES forKey:kSound]; AppDelegate *s2 = makeApp(m2);
        NSUserDefaults *m3 = freshSuite(); [m3 setObject:@"Bogus" forKey:kSoundName]; AppDelegate *s3 = makeApp(m3);
        CHECK(@"SO-07", @"Version 3.0 sound switch migrates (off → None, on → Glass); unknown names fall back to Glass",
              [s1.soundName isEqualToString:@"none"] && [s2.soundName isEqualToString:@"Glass"] && [s3.soundName isEqualToString:@"Glass"], S(@"%@ %@ %@", s1.soundName, s2.soundName, s3.soundName));
    }

    // --- Themes ----------------------------------------------------------------------------
    {
        NSMutableSet *keys = [NSMutableSet set]; BOOL named = YES;
        for (Theme *t in allThemes()) { [keys addObject:t.key]; if (!t.zh.length || !t.en.length) named = NO; }
        CHECK(@"TH-01", @"Six themes with unique keys and names in both languages", allThemes().count == 6 && keys.count == 6 && named && a.themeTiles.count == 6, @"");
        NSMutableString *low = [NSMutableString string];
        for (Theme *t in allThemes()) for (NSNumber *r in @[@NO, @YES]) {
            NSArray<NSColor *> *g = [t gradient:r.boolValue];
            for (NSColor *bg in g) {
                NSColor *paint = over([bg colorWithAlphaComponent:.74 + .1 * .26], t.light ? rgb(.93, .94, .96, 1) : rgb(.11, .12, .14, 1));   // Lowest background setting over a neutral desktop.
                double ci = contrast(t.ink, paint), cm = contrast(over(t.mutedInk, paint), paint);
                if (ci < 4.5 || cm < 4.5) [low appendFormat:@"%@/%@ ink=%.1f muted=%.1f; ", t.key, r.boolValue ? @"break" : @"focus", ci, cm];
            }
            NSColor *acc = [t accent:r.boolValue];
            double cb = MIN(contrast(t.buttonInk, mix(acc, NSColor.whiteColor, t.light ? .06 : .15)), contrast(t.buttonInk, acc));   // Card gradient and the prompt's solid pill.
            if (cb < 3) [low appendFormat:@"%@ button=%.1f; ", t.key, cb];
        }
        CHECK(@"TH-02", @"Every theme keeps text contrast >= 4.5:1 and button text >= 3:1 (WCAG AA)", low.length == 0, low);
        [a showSettingsPane:2 focusDuration:NO];
        ThemeTile *rain = nil; for (ThemeTile *t in a.themeTiles) if ([t.theme.key isEqualToString:@"rain"]) rain = t;
        [rain accessibilityPerformPress];
        CHECK(@"TH-03", @"Choosing a theme previews it on the card, without saving", [a.surface.theme.key isEqualToString:@"rain"] && [a.ring.theme.key isEqualToString:@"rain"] && [a.themeKey isEqualToString:@"aurora"] && ![[d stringForKey:kTheme] isEqualToString:@"rain"] && rain.chosen, a.surface.theme.key);
        [a revertSettings:nil];
        CHECK(@"TH-04", @"Revert removes the preview", [a.surface.theme.key isEqualToString:@"aurora"] && !rain.chosen, a.surface.theme.key);
        [rain accessibilityPerformPress]; [a saveDraft];
        CHECK(@"TH-05", @"Save applies the theme to the card and stores it", [a.themeKey isEqualToString:@"rain"] && [[d stringForKey:kTheme] isEqualToString:@"rain"] && [a.surface.theme.key isEqualToString:@"rain"] && [a.timeLabel.textColor isEqual:themeNamed(@"rain").ink], [d stringForKey:kTheme]);
        AppDelegate *r2 = makeApp(d);
        CHECK(@"TH-06", @"Relaunch keeps the theme", [r2.themeKey isEqualToString:@"rain"] && [r2.surface.theme.key isEqualToString:@"rain"], r2.themeKey);
        saveSetting(a, kTheme, @"frost");
        CHECK(@"TH-07", @"The light theme (Frost) switches the card to light appearance and dark text", [a.panel.appearance.name isEqualToString:NSAppearanceNameAqua] && luminance(a.timeLabel.textColor) < .2, a.panel.appearance.name);
        saveSetting(a, kTheme, @"graphite");
        CHECK(@"TH-08", @"Dark themes use dark appearance; Graphite has no ambient motion", [a.panel.appearance.name isEqualToString:NSAppearanceNameDarkAqua] && themeNamed(@"graphite").ambient == AmbientNone, a.panel.appearance.name);
        NSUserDefaults *bt = freshSuite(); [bt setObject:@"neon" forKey:kTheme]; AppDelegate *t3 = makeApp(bt);
        CHECK(@"TH-09", @"An unknown stored theme falls back to Aurora", [t3.themeKey isEqualToString:@"aurora"], t3.themeKey);
        saveSetting(a, kAmbient, @NO);
        CHECK(@"TH-10", @"Ambient motion can be turned off and is stored", !a.ambient && ![d boolForKey:kAmbient] && !a.surface.motion, @"");
        saveSetting(a, kAmbient, @YES); saveSetting(a, kTheme, @"rain");
        CHECK(@"TH-11", @"No ambient animation runs while the card is not on screen (performance)", a.surface.spawner == nil && [a.surface.gradient animationForKey:@"drift"] == nil && a.surface.fx.sublayers.count == 0, @"");
        BOOL fits = YES; NSMutableString *tf = [NSMutableString string];
        for (Theme *t in allThemes()) { saveSetting(a, kTheme, t.key); for (NSTextField *l in cardTexts(a)) if (![l.textColor isEqual:([l isEqual:a.stateLabel] || [l isEqual:a.roundsLabel]) ? t.mutedInk : t.ink]) { fits = NO; [tf appendFormat:@"%@ ", t.key]; } }
        CHECK(@"TH-12", @"Every theme colors all card texts", fits, tf);
        saveSetting(a, kTheme, @"aurora");
    }

    // --- Settings: draft, Save and Revert -------------------------------------------------
    {
        [a showSettingsPane:0 focusDuration:NO];
        CHECK(@"SV-01", @"Settings open clean: Save disabled, 'saved' status", ![a settingsDirty] && !a.saveButton.enabled && !a.revertButton.enabled && a.statusLabel.stringValue.length > 0, a.statusLabel.stringValue);
        a.pinSwitch.state = NSControlStateValueOn; [a switchChanged:a.pinSwitch];
        CHECK(@"SV-02", @"A change marks the draft: Save enabled, '1 unsaved change', nothing stored yet", [a settingsDirty] && a.saveButton.enabled && a.revertButton.enabled && a.settingsWindow.documentEdited
              && [a.statusLabel.stringValue isEqualToString:T(@"1 项未保存的更改", @"1 unsaved change")] && !a.pinned && ![d boolForKey:kPinned] && a.panel.level < NSNormalWindowLevel, a.statusLabel.stringValue);
        a.menuTimeSwitch.state = NSControlStateValueOff; [a switchChanged:a.menuTimeSwitch];
        a.focusStepper.integerValue = 26; [a stepDuration:a.focusStepper];
        CHECK(@"SV-03", @"Several changes are counted", [a.statusLabel.stringValue isEqualToString:T(@"3 项未保存的更改", @"3 unsaved changes")] && [a dirtyKeys].count == 3, a.statusLabel.stringValue);
        a.focusStepper.integerValue = 25; [a stepDuration:a.focusStepper];
        CHECK(@"SV-04", @"Changing a value back removes it from the count", [a dirtyKeys].count == 2, [[a dirtyKeys] componentsJoinedByString:@","]);
        [a revertSettings:nil];
        CHECK(@"SV-05", @"Revert drops every change", ![a settingsDirty] && a.pinSwitch.state == NSControlStateValueOff && a.menuTimeSwitch.state == NSControlStateValueOn && !a.saveButton.enabled, @"");
        a.pinSwitch.state = NSControlStateValueOn; [a switchChanged:a.pinSwitch]; BOOL saved = [a saveDraft];
        CHECK(@"SV-06", @"Save stores the change, applies it and confirms with the time", saved && a.pinned && [d boolForKey:kPinned] && a.panel.level == NSFloatingWindowLevel && ![a settingsDirty] && !a.saveButton.enabled
              && [a.statusLabel.stringValue hasPrefix:T(@"已保存 · ", @"Saved · ")], a.statusLabel.stringValue);
        saveSetting(a, kPinned, @NO);
        CHECK(@"SV-07", @"Turning it off keeps the card below regular application windows", a.panel.level < NSNormalWindowLevel && ![d boolForKey:kPinned], @"");
        [a durationEditedText:@"abc" rest:NO];
        CHECK(@"SV-08", @"An invalid length is explained and the field returns to the last valid value", [a.focusField.stringValue isEqualToString:@"25"] && [a.durationNote.textColor isEqual:NSColor.systemRedColor], a.durationNote.stringValue);
        a.focusField.stringValue = @"0"; [a controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:a.focusField]];
        CHECK(@"SV-09", @"While the field holds an invalid value, Save is disabled and the status says why", a.durationInvalid && !a.saveButton.enabled && ![a saveDraft] && [a.statusLabel.stringValue isEqualToString:T(@"时长无效，请输入 1–180", @"Fix the length (1 to 180)")], a.statusLabel.stringValue);
        a.focusField.stringValue = @"30"; [a controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:a.focusField]];
        CHECK(@"SV-10", @"Typing a valid value enables Save again", !a.durationInvalid && a.saveButton.enabled && [a.draft[kFocus] integerValue] == 30, @"");
        [a revertSettings:nil];
        [a showSettingsPane:1 focusDuration:NO];
        CHECK(@"SV-11", @"Auto-start options are hidden with the full-screen prompt", a.autoStartGroup.hidden, @"");
        [a.completionPopup selectItemAtIndex:1]; [a completionChosen:a.completionPopup];
        CHECK(@"SV-12", @"…and shown for 'Notification only' (in the draft, before Save)", !a.autoStartGroup.hidden && [a.completionStyle isEqualToString:kOverlay], @"");
        [a revertSettings:nil];
        CHECK(@"SV-13", @"Revert hides them again", a.autoStartGroup.hidden, @"");
        NSMutableString *heights = [NSMutableString string]; BOOL panesOK = YES, oneSelected = YES;
        for (NSInteger p = 0; p < 4; p++) {
            [a paneChosen:a.paneButtons[p]];
            NSInteger sel = 0; for (PaneButton *b in a.paneButtons) if (b.selectedPane) sel++;
            if (sel != 1 || !a.paneButtons[p].selectedPane || a.currentPane != p) oneSelected = NO;
            CGFloat h = a.settingsWindow.frame.size.height; [heights appendFormat:@"%.0f ", h];
            if (h > 700 || h < 250) panesOK = NO;
        }
        CHECK(@"SV-14", @"Four panes; exactly one tab is selected; the window fits each pane (250-700 pt)", oneSelected && panesOK, heights);
        [a paneChosen:a.paneButtons[0]];
        saveSetting(a, kTheme, @"water"); saveSetting(a, kSoundName, @"Purr"); saveSetting(a, kCompletion, kBanner); saveSetting(a, kAmbient, @NO); saveSetting(a, kOpacity, @.7);
        AppDelegate *p2 = makeApp(d);
        CHECK(@"SV-15", @"Theme, sound, prompt style, motion and background survive a relaunch", [p2.themeKey isEqualToString:@"water"] && [p2.soundName isEqualToString:@"Purr"] && [p2.completionStyle isEqualToString:kBanner] && !p2.ambient && fabs(p2.glassOpacity - .7) < .001, @"");
        [a showSettingsPane:3 focusDuration:NO]; [a restoreDefaults:nil];
        CHECK(@"SV-16", @"Restore Defaults fills the draft only (nothing stored until Save)", [a settingsDirty] && [a.themeKey isEqualToString:@"water"] && [[d stringForKey:kTheme] isEqualToString:@"water"] && [a.surface.theme.key isEqualToString:@"aurora"], @"");
        NSInteger kept = a.statsSessions; [a saveDraft];
        CHECK(@"SV-17", @"Save after Restore Defaults stores the defaults and keeps today's stats", [a.themeKey isEqualToString:@"aurora"] && [a.soundName isEqualToString:@"Glass"] && [a.completionStyle isEqualToString:kOverlay] && a.ambient && fabs(a.glassOpacity - .45) < .001 && a.statsSessions == kept, @"");
        a.fakeLogin = NO; saveSetting(a, kLogin, @YES);
        CHECK(@"SV-18", @"Open at login is applied on Save (test stand-in; the real login item is not touched)", a.fakeLogin && ![a settingsDirty], @"");
        saveSetting(a, kLogin, @NO);
        [a showSettingsPane:3 focusDuration:NO];
        CHECK(@"LG-01", @"General has a Language choice: System, 简体中文, English (System by default)", a.languagePopup.numberOfItems == 3 && [a.languagePopup.selectedItem.representedObject isEqualToString:@"system"]
              && [a.languagePopup.itemArray[1].title isEqualToString:@"简体中文"] && [a.languagePopup.itemArray[2].title isEqualToString:@"English"], a.languagePopup.selectedItem.title);
        NSString *other = gChinese ? @"en" : @"zh";
        [a.languagePopup selectItemAtIndex:gChinese ? 2 : 1]; [a languageChosen:a.languagePopup];
        CHECK(@"LG-02", @"Choosing the other language marks the draft and explains that it applies after Save and relaunch", [a settingsDirty] && a.relaunchButton.hidden && a.languageNote.stringValue.length > 0 && ![[d stringForKey:kLanguage] isEqualToString:other], a.languageNote.stringValue);
        [a saveDraft];
        CHECK(@"LG-03", @"Save stores the language and offers 'Relaunch Now'", [[d stringForKey:kLanguage] isEqualToString:other] && !a.relaunchButton.hidden, [d stringForKey:kLanguage]);
        [a relaunch:a.relaunchButton];
        CHECK(@"LG-04", @"Relaunch is requested (tests do not quit the process)", [a.alertLog.lastObject isEqualToString:@"relaunch"], a.alertLog.lastObject);
        saveSetting(a, kLanguage, gChinese ? @"zh" : @"en");
        CHECK(@"LG-05", @"Choosing the language in use needs no relaunch", a.relaunchButton.hidden, @"");
        saveSetting(a, kLanguage, @"system");
        AppDelegate *l2 = makeApp(d);
        CHECK(@"LG-06", @"The language setting survives a relaunch; unknown values mean System", [l2.languagePref isEqualToString:@"system"] && ({ NSUserDefaults *lx = freshSuite(); [lx setObject:@"fr" forKey:kLanguage]; [makeApp(lx).languagePref isEqualToString:@"system"]; }), l2.languagePref);
    }

    // --- Settings: lengths --------------------------------------------------------------------
    [a showSettingsPane:0 focusDuration:NO];
    [a durationEditedText:@"30" rest:NO];
    CHECK(@"SE-01", @"A new length waits for Save", a.focusMinutes == 25 && [a.timeLabel.stringValue isEqualToString:@"25:00"] && a.saveButton.enabled, a.timeLabel.stringValue);
    [a saveDraft];
    CHECK(@"SE-02", @"After Save, the idle timer shows the new length", a.focusMinutes == 30 && [a.timeLabel.stringValue isEqualToString:@"30:00"] && [d integerForKey:kFocus] == 30, a.timeLabel.stringValue);
    a.focusStepper.integerValue = 31; [a stepDuration:a.focusStepper]; [a saveDraft];
    CHECK(@"SE-03", @"Stepper change updates the field and, after Save, the timer", [a.focusField.stringValue isEqualToString:@"31"] && [a.timeLabel.stringValue isEqualToString:@"31:00"], a.focusField.stringValue);
    NSArray *bad = @[@"abc", @"0", @"181", @"12.5", @"-3", @"", @"  "];
    BOOL allRejected = YES;
    for (NSString *b in bad) { [a durationEditedText:b rest:NO]; if ([a.draft[kFocus] integerValue] != 31 || ![a.focusField.stringValue isEqualToString:@"31"]) allRejected = NO; }
    CHECK(@"SE-04", @"Invalid lengths are rejected and the field reverts", allRejected && ![a settingsDirty], a.focusField.stringValue);
    CHECK(@"SE-05", @"Invalid length shows an inline red message", [a.durationNote.textColor isEqual:NSColor.systemRedColor] && a.durationNote.stringValue.length > 0, a.durationNote.stringValue);
    [a durationEditedText:@"１８０" rest:NO]; [a saveDraft];
    CHECK(@"SE-06", @"Full-width digits are accepted (Chinese IME)", a.focusMinutes == 180 && [a.timeLabel.stringValue isEqualToString:@"180:00"], a.timeLabel.stringValue);
    CHECK(@"SE-07", @"A valid entry clears the error message", ![a.durationNote.textColor isEqual:NSColor.systemRedColor], @"");
    CHECK(@"UI-T01", @"180:00 fits in the time label", textWidth(a.timeLabel) <= a.timeLabel.frame.size.width - 4, S(@"%.0f/%.0f", textWidth(a.timeLabel), a.timeLabel.frame.size.width));
    [a durationEditedText:@"25" rest:NO]; [a saveDraft];
    [a toggle:nil]; gClockOffset += 60; [a durationEditedText:@"50" rest:NO]; [a saveDraft];
    CHECK(@"SE-08", @"Running length change waits for the next phase", a.focusMinutes == 50 && [a.timeLabel.stringValue isEqualToString:@"24:00"], a.timeLabel.stringValue);
    CHECK(@"SE-09", @"Settings note explains the deferred change", [a.durationNote.stringValue isEqualToString:T(@"计时进行中：新时长从下一段开始生效。", @"A timer is running. A new length applies from the next phase.")], a.durationNote.stringValue);
    [a reset:nil];
    CHECK(@"SE-10", @"Reset applies the new length", [a.timeLabel.stringValue isEqualToString:@"50:00"], a.timeLabel.stringValue);
    [a durationEditedText:@"7" rest:YES]; [a saveDraft];
    CHECK(@"SE-11", @"Break length while in focus does not change the focus timer", a.breakMinutes == 7 && [a.timeLabel.stringValue isEqualToString:@"50:00"], a.timeLabel.stringValue);
    [a showSettingsPane:2 focusDuration:NO];
    a.opacitySlider.doubleValue = .8; [a opacityChanged:a.opacitySlider];
    CHECK(@"SE-12", @"Background slider previews on the card without saving", fabs(a.surface.opacity - .8) < .001 && fabs([d doubleForKey:kOpacity] - .45) < .001, S(@"%.2f", a.surface.opacity));
    [a saveDraft];
    CHECK(@"SE-13", @"Save stores the background", fabs([d doubleForKey:kOpacity] - .8) < .001 && fabs(a.surface.opacity - .8) < .001, @"");
    saveSetting(a, kMenuTime, @NO); [a toggle:nil];
    CHECK(@"SE-14", @"Menu bar time can be turned off", a.statusTitle.length == 0, a.statusTitle);
    saveSetting(a, kMenuTime, @YES);
    CHECK(@"SE-15", @"Menu bar time comes back when turned on", a.statusTitle.length == 5, a.statusTitle);
    [a reset:nil];
    [a showSettingsPane:1 focusDuration:NO]; a.notifySwitch.state = NSControlStateValueOff; [a switchChanged:a.notifySwitch];
    CHECK(@"SE-16", @"Notifications off disables the permission button and explains what still works", !a.permissionButton.enabled && a.permissionLabel.stringValue.length > 0, a.permissionLabel.stringValue);
    a.notifySwitch.state = NSControlStateValueOn; [a switchChanged:a.notifySwitch];
    CHECK(@"SE-17", @"Notifications on enables a permission action", a.permissionButton.enabled && a.permissionButton.title.length > 0, a.permissionButton.title);
    [a revertSettings:nil];
    saveSetting(a, kFocus, @25); saveSetting(a, kBreak, @5); saveSetting(a, kOpacity, @.45);

    // --- Double-click the paused time to change the length ----------------------------------
    {
        NSPoint onTime = NSMakePoint(NSMidX(a.timeLabel.frame), NSMidY(a.timeLabel.frame));
        [a toggle:nil]; gClockOffset += 600; [a toggle:nil];   // 10 min used of 25
        CHECK(@"DC-02", @"Paused: double-click on the time opens Settings at the Focus length", [a handleDoubleClickAt:onTime] && a.currentPane == 0
              && (a.settingsWindow.firstResponder == a.focusField || [(id)a.settingsWindow.firstResponder delegate] == (id)a.focusField), S(@"pane=%ld fr=%@", (long)a.currentPane, a.settingsWindow.firstResponder.className));
        CHECK(@"DC-03", @"Paused: double-click away from the time does nothing", ![a handleDoubleClickAt:NSMakePoint(20, NSMaxY(a.card.bounds) - 20)], @"");
        CHECK(@"DC-05", @"The note says the paused phase will use the new length", [a.durationNote.stringValue isEqualToString:T(@"计时已暂停：保存后，这一段按新时长继续（已用时间保留）。", @"Paused: after you save, this phase continues with the new length (time used is kept).")], a.durationNote.stringValue);
        [a durationEditedText:@"40" rest:NO]; [a saveDraft];
        CHECK(@"DC-06", @"Save while paused: 40 min with 10 used shows 30:00, still paused", a.paused && [a.timeLabel.stringValue isEqualToString:@"30:00"] && a.sessionDuration == 2400 && fabs(a.ring.progress - .25) < .001, S(@"%@ %.0f", a.timeLabel.stringValue, a.sessionDuration));
        [a toggle:nil]; gClockOffset += 2; [a refresh];
        CHECK(@"DC-07", @"Resume continues from the new remaining time", a.running && [a.timeLabel.stringValue isEqualToString:@"29:58"], a.timeLabel.stringValue);
        [a toggle:nil]; [a handleDoubleClickAt:onTime]; [a durationEditedText:@"5" rest:NO]; [a saveDraft];
        CHECK(@"DC-08", @"A length shorter than the time used leaves 00:00, paused", a.paused && [a secondsRemaining] == 0 && [a.timeLabel.stringValue isEqualToString:@"00:00"], a.timeLabel.stringValue);
        NSInteger s0 = a.statsSessions; [a toggle:nil];
        CHECK(@"DC-09", @"Resume at 00:00 finishes the phase (counted, prompt shown)", a.rest && !a.started && a.statsSessions == s0 + 1 && a.overlay.visible, S(@"rest=%d", a.rest));
        [a overlayPrimary:nil]; [a toggle:nil];
        CHECK(@"DC-10", @"Paused break: double-click focuses the Break length", [a handleDoubleClickAt:onTime] && (a.settingsWindow.firstResponder == a.breakField || [(id)a.settingsWindow.firstResponder delegate] == (id)a.breakField), a.settingsWindow.firstResponder.className);
        [a revertSettings:nil]; [a reset:nil]; [a skip:nil]; saveSetting(a, kFocus, @25);
    }

    // --- Menus ------------------------------------------------------------------------
    CHECK(@"MB-01", @"Status menu Start item mirrors the card button", [a.menuToggle.title isEqualToString:a.startButton.title], a.menuToggle.title);
    CHECK(@"MB-02", @"Reset menu item is disabled when idle", ![a validateMenuItem:a.menuReset], @"");
    [a toggle:nil];
    CHECK(@"MB-03", @"Reset menu item is enabled when started", [a validateMenuItem:a.menuReset], @"");
    CHECK(@"MB-04", @"Menu header shows phase and time left", [a.menuState.title containsString:@"25:00"] || [a.menuState.title containsString:@"24:5"], a.menuState.title);
    CHECK(@"MB-05", @"Menu shows today's count", [a.menuToday.title containsString:S(@"%ld", (long)a.statsSessions)], a.menuToday.title);
    CHECK(@"MB-06", @"Card item offers Show while the card is hidden", [a.menuCard.title isEqualToString:T(@"显示卡片", @"Show Card")], a.menuCard.title);
    CHECK(@"MB-07", @"Header and today items are not clickable", a.menuState.action == nil && a.menuToday.action == nil, @"");
    [a reset:nil];

    // --- Keyboard -----------------------------------------------------------------------
    NSEvent *space = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:a.panel.windowNumber context:nil characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
    [a.panel keyDown:space];
    CHECK(@"KB-01", @"Space on the card starts the timer", a.running, @"");
    [a.panel keyDown:space];
    CHECK(@"KB-02", @"Space again pauses the timer", a.paused, @"");
    NSEvent *cmdSpace = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:a.panel.windowNumber context:nil characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
    [a.panel keyDown:cmdSpace];
    CHECK(@"KB-03", @"Command-Space is ignored by the card", a.paused, @"");
    [a.panel performClose:nil];
    CHECK(@"KB-04", @"Command-W hides the card and keeps the timer", !a.cardVisible && a.paused && ![d boolForKey:kCardVisible], @"");
    [a reset:nil];

    // --- Rapid and repeated actions -----------------------------------------------------
    NSInteger keptSessions = a.statsSessions;
    BOOL stable = YES;
    for (int i = 0; i < 51; i++) { [a toggle:nil]; gClockOffset += 0.37; [a refresh]; if ([a secondsRemaining] > a.sessionDuration || [a secondsRemaining] < 0) stable = NO; }
    CHECK(@"RB-01", @"51 rapid Start/Pause clicks leave a valid running state", stable && a.running && [a secondsRemaining] <= 1500, S(@"%ld", (long)[a secondsRemaining]));
    for (int i = 0; i < 101; i++) [a skip:nil];
    CHECK(@"RB-02", @"101 rapid skips end in break, idle, no sessions counted", a.rest && !a.started && a.statsSessions == keptSessions, @"");
    [a skip:nil];
    for (int i = 0; i < 20; i++) [a reset:nil];
    CHECK(@"RB-03", @"Repeated Reset is harmless", !a.started && [a secondsRemaining] == 1500, @"");
    {
        BOOL ok = YES;
        for (int i = 0; i < 30; i++) { ThemeTile *t = a.themeTiles[i % 6]; [t accessibilityPerformPress]; if (![a.surface.theme.key isEqualToString:t.theme.key]) ok = NO; }
        [a revertSettings:nil];
        CHECK(@"RB-04", @"30 rapid theme switches preview correctly; Revert restores the saved theme", ok && [a.surface.theme.key isEqualToString:a.themeKey], a.surface.theme.key);
    }

    // --- Persistence --------------------------------------------------------------------
    [a toggle:nil]; gClockOffset += 100; [a refresh]; double deadline = a.countdown.deadline; [a save];
    AppDelegate *b = makeApp(d);
    CHECK(@"PS-01", @"Relaunch restores a running timer with the same end time", b.running && b.countdown.deadline == deadline && [b.timeLabel.stringValue isEqualToString:@"23:20"], b.timeLabel.stringValue);
    [b toggle:nil]; [b save];
    AppDelegate *b2 = makeApp(d);
    CHECK(@"PS-02", @"Relaunch restores a paused timer", b2.paused && [b2.timeLabel.stringValue isEqualToString:@"23:20"], b2.timeLabel.stringValue);
    [b2 skip:nil]; [b2 save];
    AppDelegate *b3 = makeApp(d);
    CHECK(@"PS-03", @"Relaunch restores the phase", b3.rest && [b3.timeLabel.stringValue isEqualToString:@"05:00"], b3.timeLabel.stringValue);
    NSSet *allowed = [NSSet setWithArray:knownKeys()];
    NSMutableSet *written = [NSMutableSet setWithArray:[[d persistentDomainForName:kSuite] allKeys]];
    for (NSString *k in written.allObjects) if ([k hasPrefix:@"NSWindow Frame"]) [written removeObject:k];
    CHECK(@"PV-01", @"Preferences hold only known timer and setting keys", [written isSubsetOfSet:allowed] && ![written containsObject:kLogin], [written.allObjects componentsJoinedByString:@","]);

    // --- Damaged or unusual stored data ----------------------------------------------------
    NSUserDefaults *bad2 = freshSuite();
    [bad2 setObject:@0 forKey:kFocus]; [bad2 setObject:@999 forKey:kBreak]; [bad2 setObject:@(-50) forKey:kRemaining];
    [bad2 setObject:@"garbage" forKey:kEnd]; [bad2 setObject:@5 forKey:kOpacity]; [bad2 setObject:@"junk" forKey:kDuration]; [bad2 setObject:@(-4) forKey:kStatsSessions];
    [bad2 setObject:@42 forKey:kCompletion]; [bad2 setObject:@[] forKey:kSoundName];
    AppDelegate *c1 = makeApp(bad2);
    CHECK(@"ED-01", @"Damaged preferences fall back to safe values", c1.focusMinutes == 25 && c1.breakMinutes == 5 && fabs(c1.glassOpacity - .45) < .001 && !c1.running && [c1.timeLabel.stringValue isEqualToString:@"25:00"] && c1.statsSessions == 0
          && [c1.completionStyle isEqualToString:kOverlay] && [c1.soundName isEqualToString:@"Glass"], c1.timeLabel.stringValue);
    NSUserDefaults *future = freshSuite();
    [future setObject:@1500 forKey:kDuration]; [future setObject:@(clockNow() + 86400) forKey:kEnd];
    AppDelegate *c2 = makeApp(future);
    CHECK(@"ED-02", @"An end time far in the future (clock moved back) is capped", [c2 secondsRemaining] <= 1500, S(@"%ld", (long)[c2 secondsRemaining]));
    NSUserDefaults *old = freshSuite();
    [old setObject:@"2000-01-01" forKey:kStatsDay]; [old setObject:@9 forKey:kStatsSessions];
    AppDelegate *c3 = makeApp(old);
    CHECK(@"ED-03", @"Stats from an earlier day reset to zero", c3.statsSessions == 0 && [c3.statsDay isEqualToString:dayKey(clockNow())], @"");
    c3.statsSessions = 3; [c3 save]; [c3 refreshForce:YES]; gClockOffset += 86400; [c3 refresh];
    CHECK(@"ED-04", @"Stats reset at midnight while the app runs (header shows 0)", c3.statsSessions == 0 && [c3.roundsLabel.stringValue isEqualToString:T(@"今日 0 轮", @"0 today")], c3.roundsLabel.stringValue);
    NSUserDefaults *legacy = freshSuite();
    [legacy setObject:@40 forKey:kFocus]; [legacy setObject:@1 forKey:kRest]; [legacy setObject:@300 forKey:kDuration]; [legacy setObject:@120 forKey:kRemaining];
    AppDelegate *c4 = makeApp(legacy);
    CHECK(@"ED-05", @"Version 2 preferences migrate (paused break, 02:00 left)", c4.rest && c4.paused && c4.focusMinutes == 40 && [c4.timeLabel.stringValue isEqualToString:@"02:00"], c4.timeLabel.stringValue);

    // --- Compact card -------------------------------------------------------------------------
    {
        NSUserDefaults *cd = freshSuite(); AppDelegate *k = makeApp(cd);
        CHECK(@"CM-01", @"Full card is 300 x 350 pt by default", NSEqualSizes(k.card.frame.size, NSMakeSize(kCardW, kCardH)) && !k.compact, NSStringFromSize(k.card.frame.size));
        [k toggleCompact:nil];
        CHECK(@"CM-02", @"Compact button switches to a 280 x 144 pt landscape card and saves it", NSEqualSizes(k.card.frame.size, NSMakeSize(kCompactW, kCompactH)) && k.compact && [cd boolForKey:kCompact], NSStringFromSize(k.card.frame.size));
        NSMutableArray *visible = [NSMutableArray array]; NSMutableString *bad = [NSMutableString string];
        for (NSView *v in @[k.phaseIcon, k.phaseLabel, k.roundsLabel, k.compactButton, k.settingsButton, k.hideButton, k.ring, k.timeLabel, k.stateLabel, k.resetButton, k.startButton, k.skipButton])
            if (!v.hidden && v.alphaValue > 0) { [visible addObject:v]; if (!inside(v, k.card)) [bad appendFormat:@"%@ outside; ", v.className]; }
        NSArray *solid = [visible filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id v, NSDictionary *bb) { return v != k.ring; }]];
        for (NSUInteger i = 0; i < solid.count; i++) for (NSUInteger j = i + 1; j < solid.count; j++)
            if (NSIntersectsRect([solid[i] frame], [solid[j] frame])) [bad appendFormat:@"%lu∩%lu; ", (unsigned long)i, (unsigned long)j];
        CHECK(@"CM-03", @"Compact layout: visible controls inside the card, no overlap", bad.length == 0, bad);
        CHECK(@"CM-04", @"Compact hides Settings (out of the tab order) and keeps the state and rounds", k.settingsButton.hidden && !k.stateLabel.hidden && !k.roundsLabel.hidden && k.roundsLabel.alphaValue == 1, @"");
        CHECK(@"CM-15", @"The theme background layers follow the compact size", NSEqualRects(k.surface.gradient.frame, k.surface.bounds) && k.surface.bounds.size.width == kCompactW, NSStringFromRect(k.surface.gradient.frame));
        CHECK(@"CM-16", @"No system window shadow (it outlines the card); the card's own soft shadow follows its shape", !k.panel.hasShadow && k.cardShadow.shadowOpacity > 0
              && NSEqualRects(k.cardShadow.frame, k.card.frame) && NSEqualSizes(k.panel.frame.size, NSMakeSize(kCompactW + 2 * kPad, kCompactH + 2 * kPad)) && NSEqualPoints(k.card.frame.origin, NSMakePoint(kPad, kPad)),
              S(@"%@ %@", NSStringFromRect(k.cardShadow.frame), NSStringFromSize(k.panel.frame.size)));
        CHECK(@"CM-12", @"Compact card is landscape (width about 2x height)", kCompactW / kCompactH > 1.8 && kCompactW / kCompactH < 2.2, @"");
        {
            double savedClock = gClockOffset;
            NSUserDefaults *fd = freshSuite(); AppDelegate *f2 = makeApp(fd); [f2 toggleCompact:nil];
            NSMutableString *cut = [NSMutableString string];
            void (^fits)(void) = ^{ [f2 refreshForce:YES]; for (NSTextField *l in @[f2.stateLabel, f2.roundsLabel]) if (textWidth(l) > l.frame.size.width) [cut appendFormat:@"[%@] ", l.stringValue]; };
            fits(); [f2 toggle:nil]; fits(); [f2 toggle:nil]; fits(); [f2 reset:nil];
            [f2 toggle:nil]; gClockOffset += f2.sessionDuration + .5; [f2 refresh]; fits();   // focus done
            [f2 overlayPrimary:nil]; fits();                                                // break running
            gClockOffset += f2.sessionDuration + .5; [f2 refresh]; fits();                  // break over
            [f2 overlaySecondary:nil]; [f2 toggle:nil]; gClockOffset += f2.sessionDuration + 7200; [f2 refresh]; fits();   // late completion
            f2.statsSessions = 99; fits();
            CHECK(@"CM-13", @"Every compact state text and the rounds count fit without truncation", cut.length == 0, cut);
            gClockOffset = savedClock;
        }
        CHECK(@"CM-05", @"Compact primary is a round play icon with a full accessible name", k.startButton.round && k.startButton.image && [[k.startButton accessibilityLabel] isEqualToString:T(@"开始专注", @"Start Focus")], [k.startButton accessibilityLabel]);
        [k toggle:nil];
        CHECK(@"CM-06", @"Compact primary changes to a pause icon while running", k.running && [k.startButton.image.accessibilityDescription isEqualToString:T(@"暂停", @"Pause")], k.startButton.image.accessibilityDescription);
        CHECK(@"CM-07", @"180:00 fits in the compact time label", ({ k.timeLabel.stringValue = @"180:00"; textWidth(k.timeLabel) <= k.timeLabel.frame.size.width - 4; }), S(@"%.0f", textWidth(k.timeLabel)));
        [k toggle:nil];
        CHECK(@"CM-14", @"Compact paused card: the time is still double-click editable", NSContainsRect(k.card.editableRect, k.timeLabel.frame) && [k handleDoubleClickAt:NSMakePoint(NSMidX(k.timeLabel.frame), NSMidY(k.timeLabel.frame))], NSStringFromRect(k.card.editableRect));
        [k revertSettings:nil]; [k toggle:nil];
        [k refreshForce:YES]; [k save];
        AppDelegate *k2 = makeApp(cd);
        CHECK(@"CM-08", @"Relaunch restores the compact card and the running timer", k2.compact && k2.running && NSEqualSizes(k2.card.frame.size, NSMakeSize(kCompactW, kCompactH)), NSStringFromSize(k2.card.frame.size));
        [k2 toggleCompact:nil];
        CHECK(@"CM-09", @"Switching back restores the full card with every control visible", NSEqualSizes(k2.card.frame.size, NSMakeSize(kCardW, kCardH)) && !k2.settingsButton.hidden && k2.settingsButton.alphaValue == 1 && k2.startButton.image == nil, @"");
        [k2 menuNeedsUpdate:k2.statusMenu];
        CHECK(@"CM-10", @"Status menu 'Compact Card' shows the current mode", k2.menuCompact.state == NSControlStateValueOff, @"");
        CHECK(@"CM-11", @"Compact button names the action it performs", [[k2.compactButton accessibilityLabel] isEqualToString:T(@"紧凑卡片", @"Compact card")], [k2.compactButton accessibilityLabel]);
    }
    // --- Icons --------------------------------------------------------------------------------
    {
        BOOL allSymbols = YES; NSMutableString *miss = [NSMutableString string];
        for (NSString *n in @[@"hourglass", @"cup.and.saucer.fill", @"pause.circle", @"play.fill", @"pause.fill", @"arrow.counterclockwise", @"forward.end.fill", @"gearshape", @"minus",
                              @"arrow.down.right.and.arrow.up.left", @"arrow.up.left.and.arrow.down.right", @"timer", @"bell", @"paintpalette", @"checkmark",
                              @"checkmark.circle", @"checkmark.circle.fill", @"circle.fill", @"exclamationmark.triangle.fill"])
            if (![NSImage imageWithSystemSymbolName:n accessibilityDescription:nil]) { allSymbols = NO; [miss appendFormat:@"%@ ", n]; }
        CHECK(@"IC-01", @"Every icon resolves from one SF Symbols set", allSymbols, miss);
        CHECK(@"IC-02", @"Menu bar icons are template images (adapt to light and dark menu bars)", menuImage(NO).template && menuImage(YES).template, @"");
        CHECK(@"IC-03", @"Header buttons are quiet (no fill until hover)", a.compactButton.quiet && a.settingsButton.quiet && a.hideButton.quiet && !a.resetButton.quiet, @"");
    }

    // --- Layout and accessibility -----------------------------------------------------------
    NSString *lang = gChinese ? @"zh" : @"en";
    layoutChecks(a, lang);
    BOOL titlesFit = YES; NSMutableString *fit = [NSMutableString string];
    if (a.rest) [a skip:nil]; [a reset:nil];
    for (int s = 0; s < 5; s++) {
        if (s == 1 || s == 2) [a toggle:nil];
        if (s == 3) { [a reset:nil]; [a skip:nil]; }
        if (s == 4) { a.statsSessions = 99; [a refreshForce:YES]; }
        if (titleWidth(a.startButton) > a.startButton.frame.size.width - 16) { titlesFit = NO; [fit appendFormat:@"%@ ", a.startButton.title]; }
        for (NSTextField *l in @[a.stateLabel, a.roundsLabel, a.phaseLabel]) if (textWidth(l) > l.frame.size.width) { titlesFit = NO; [fit appendFormat:@"[%@] ", l.stringValue]; }
    }
    a.statsSessions = 0; [a skip:nil];
    CHECK(S(@"UI-T02-%@", lang), @"All card texts fit without truncation in every state", titlesFit, fit);
    BOOL ax = YES;
    for (NSButton *bt in @[a.resetButton, a.skipButton, a.compactButton, a.settingsButton, a.hideButton, a.startButton])
        if ([bt accessibilityLabel].length == 0 || ![[bt accessibilityRole] isEqualToString:NSAccessibilityButtonRole] || !bt.isAccessibilityElement) ax = NO;
    CHECK(@"AX-01", @"Every card button is an accessibility button with a label", ax, @"");
    BOOL pressed = [a.startButton accessibilityPerformPress]; BOOL runningAfterPress = a.running; [a toggle:nil];
    CHECK(@"AX-04", @"Accessibility press on the primary button starts the timer", pressed && runningAfterPress, @"");
    [a reset:nil];
    CHECK(@"AX-05", @"Disabled Reset refuses an accessibility press", ![a.resetButton accessibilityPerformPress] && !a.started, @"");
    CHECK(@"AX-06", @"Progress ring is an accessibility progress indicator with a value", [[a.ring accessibilityRole] isEqualToString:NSAccessibilityProgressIndicatorRole] && [[a.ring accessibilityValue] hasSuffix:@"%"], [a.ring accessibilityValue]);
    CHECK(@"AX-02", @"Time label reads phase and time left", [[a.timeLabel accessibilityLabel] containsString:@"5"], [a.timeLabel accessibilityLabel]);
    BOOL axSettings = YES; NSMutableString *axd = [NSMutableString string];
    for (NSView *v in @[a.focusField, a.breakField, a.opacitySlider, a.soundPopup, a.completionPopup, a.previewButton, a.autoBreakSwitch, a.autoFocusSwitch, a.notifySwitch, a.ambientSwitch, a.pinSwitch, a.menuTimeSwitch, a.loginSwitch])
        if ([v accessibilityLabel].length == 0) { axSettings = NO; [axd appendFormat:@"%@ ", v.className]; }
    for (ThemeTile *t in a.themeTiles) if (![[t accessibilityRole] isEqualToString:NSAccessibilityRadioButtonRole] || ![[t accessibilityLabel] containsString:t.theme.name]) { axSettings = NO; [axd appendString:@"tile "]; }
    for (PaneButton *p in a.paneButtons) if (![[p accessibilityRole] isEqualToString:NSAccessibilityRadioButtonRole] || [p accessibilityLabel].length == 0) { axSettings = NO; [axd appendString:@"pane "]; }
    CHECK(@"AX-03", @"Every Settings control has an accessible name; tabs and theme tiles are radio buttons", axSettings, axd);
    NSView *content = a.settingsWindow.contentView;
    BOOL setInside = YES; NSMutableString *sd = [NSMutableString string];
    NSArray *paneControls = @[@[a.focusField, a.breakField, a.focusStepper, a.breakStepper, a.durationNote],
                              @[a.completionPopup, a.soundPopup, a.previewButton, a.notifySwitch, a.permissionButton, a.permissionLabel],
                              @[a.themeTiles.firstObject, a.themeTiles.lastObject, a.ambientSwitch, a.opacitySlider, a.pinSwitch],
                              @[a.menuTimeSwitch, a.loginSwitch, a.loginNote, a.restoreButton, a.versionLabel]];
    for (NSInteger p = 0; p < 4; p++) {
        [a paneChosen:a.paneButtons[p]]; [content layoutSubtreeIfNeeded];
        NSRect paneArea = a.paneHost.frame;
        for (NSView *v in paneControls[p]) { NSRect r = [content convertRect:v.bounds fromView:v];
            if (!NSContainsRect(NSInsetRect(paneArea, -.5, -.5), r) || v.window != a.settingsWindow) { setInside = NO; [sd appendFormat:@"p%ld:%@ %@; ", (long)p, v.className, NSStringFromRect(r)]; } }
    }
    [a paneChosen:a.paneButtons[0]];
    CHECK(S(@"UI-L04-%@", lang), @"Every Settings control is inside its pane, above the Save bar", setInside, S(@"%@ host=%@", sd, NSStringFromRect(a.paneHost.frame)));
    BOOL barFits = NSMaxX(a.statusLabel.frame) < NSMinX(a.revertButton.frame) && textWidth(a.statusLabel) <= a.statusLabel.frame.size.width;
    [a showSettingsPane:0 focusDuration:NO]; a.pinSwitch.state = NSControlStateValueOn; [a switchChanged:a.pinSwitch]; a.menuTimeSwitch.state = NSControlStateValueOff; [a switchChanged:a.menuTimeSwitch];
    barFits = barFits && textWidth(a.statusLabel) <= a.statusLabel.frame.size.width;
    [a durationEditedText:@"x" rest:NO]; a.focusField.stringValue = @"x"; [a controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:a.focusField]];
    barFits = barFits && textWidth(a.statusLabel) <= a.statusLabel.frame.size.width;
    CHECK(S(@"UI-L05-%@", lang), @"Save bar texts fit beside the buttons (saved, unsaved, invalid)", barFits, a.statusLabel.stringValue);
    [a revertSettings:nil];

    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:kSuite];
    gClockOffset = 0;
    printf("SUMMARY lang=%s pass=%d fail=%d\n", gChinese ? "zh" : "en", gPass, gFail);
    if (resultsPath) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"language": gChinese ? @"zh" : @"en", @"pass": @(gPass), @"fail": @(gFail), @"results": gResults} options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:resultsPath atomically:YES];
    }
}

#pragma mark - Live UI test

static void writePNG(NSView *view, NSString *path);
static double cpuSeconds(void) {
    struct rusage u; getrusage(RUSAGE_SELF, &u);
    return u.ru_utime.tv_sec + u.ru_utime.tv_usec / 1e6 + u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}
static double residentMB(void) {
    mach_task_basic_info_data_t info; mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return info.resident_size / 1048576.0;
}

// Runs the real app (windows on screen, status item, main menu, field editor, completion prompt) in an isolated
// preferences domain and drives it with AppKit events through the normal dispatch path. Writes results and images.
static NSString *const kUISuite = @"focuscard.uitest";
static NSEvent *keyEvent(NSWindow *w, NSString *chars, unsigned short code, NSEventModifierFlags mods) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods timestamp:NSProcessInfo.processInfo.systemUptime
                        windowNumber:w.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
}
static void postClickAt(NSView *v, NSPoint local, NSInteger clicks) {
    NSWindow *w = v.window; NSPoint p = [v convertPoint:local toView:nil]; NSTimeInterval t = NSProcessInfo.processInfo.systemUptime;
    // A person's click first brings the window forward and makes it key. The test process may not be the active
    // app, and AppKit then spends a click on a non-key window just to make it key; do that step explicitly.
    if (!w.isKeyWindow && w.canBecomeKeyWindow && w.isVisible) [w makeKeyAndOrderFront:nil];
    for (NSInteger i = 1; i <= clicks; i++) {   // A double-click is two clicks; the second carries clickCount 2.
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0 timestamp:t + .08 * (i - 1) windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:i pressure:1];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0 timestamp:t + .08 * (i - 1) + .04 windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:i pressure:0];
        [NSApp postEvent:up atStart:NO];   // The control's tracking loop takes the mouse-up from the queue.
        [NSApp sendEvent:down];
    }
}
// Settings controls are pressed through accessibility (as VoiceOver does): a background test process cannot keep
// the Settings window key, and AppKit then spends a click on making the window key.
static void press(NSView *v) { [v accessibilityPerformPress]; }
static void postClick(NSView *v) { postClickAt(v, NSMakePoint(NSMidX(v.bounds), NSMidY(v.bounds)), 1); }
static void typeKeys(NSWindow *w, NSString *text) {
    for (NSUInteger i = 0; i < text.length; i++) [w sendEvent:keyEvent(w, [text substringWithRange:NSMakeRange(i, 1)], 0, 0)];
}
static BOOL menuKey(NSWindow *w, NSString *chars, unsigned short code, NSEventModifierFlags mods) {
    return [NSApp.mainMenu performKeyEquivalent:keyEvent(w, chars, code, mods)];
}
// Presses a switch through accessibility; falls back to a click-equivalent if this macOS does not support AXPress on NSSwitch.
static void toggleSwitch(NSSwitch *s) {
    NSControlStateValue before = s.state; [s accessibilityPerformPress];
    if (s.state == before) { s.state = before == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn; [s sendAction:s.action to:s.target]; }
}
static void choosePopup(NSPopUpButton *p, NSInteger index) { [p selectItemAtIndex:index]; [p sendAction:p.action to:p.target]; }

static BOOL windowIsAbove(NSWindow *front, NSWindow *back) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    NSUInteger frontIndex = NSNotFound, backIndex = NSNotFound;
    for (NSUInteger i = 0; i < windows.count; i++) {
        NSInteger number = [windows[i][(__bridge NSString *)kCGWindowNumber] integerValue];
        if (number == front.windowNumber) frontIndex = i;
        if (number == back.windowNumber) backIndex = i;
    }
    return frontIndex != NSNotFound && backIndex != NSNotFound && frontIndex < backIndex;
}

@interface UITestRunner : NSObject <NSApplicationDelegate>
@property AppDelegate *app;
@property NSString *dir;
@property NSMutableArray *results, *steps;
@property NSUInteger index;
@property NSDictionary *realPrefsBefore;
@end

@implementation UITestRunner
- (void)shot:(NSString *)name view:(NSView *)v {
    if (!v) return;
    writePNG(v, [self.dir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]]);
}
- (void)step:(NSString *)tid desc:(NSString *)desc wait:(double)wait shots:(NSArray *)shots action:(void (^)(AppDelegate *a))action check:(NSString *(^)(AppDelegate *a))check {
    [self.steps addObject:@{@"id": tid, @"desc": desc, @"wait": @(wait), @"shots": shots ?: @[], @"action": [action copy], @"check": [check copy]}];
}
- (void)saveResults {
    int pass = 0, fail = 0, blocked = 0;
    for (NSDictionary *r in self.results) { if ([r[@"status"] isEqual:@"PASS"]) pass++; else if ([r[@"status"] isEqual:@"BLOCKED"]) blocked++; else fail++; }
    NSDictionary *out = @{@"language": gChinese ? @"zh" : @"en", @"pass": @(pass), @"fail": @(fail), @"blocked": @(blocked), @"total": @(self.steps.count), @"results": self.results};
    [[NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[self.dir stringByAppendingPathComponent:@"ui-test.json"] atomically:YES];
}
- (NSView *)viewFor:(NSString *)which {
    AppDelegate *a = self.app;
    if ([which isEqual:@"card"]) return a.card;
    if ([which isEqual:@"settings"]) return a.settingsWindow.contentView.superview;
    if ([which isEqual:@"prompt"]) return a.overlay.promptCard;
    return a.statusItem.button;
}
- (void)runNext {
    if (self.index >= self.steps.count) { [self finish]; return; }
    NSDictionary *s = self.steps[self.index];
    printf("RUN  %s %s\n", [s[@"id"] UTF8String], [s[@"desc"] UTF8String]); fflush(stdout);
    ((void (^)(AppDelegate *))s[@"action"])(self.app);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([s[@"wait"] doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSMutableArray *files = [NSMutableArray array];
        for (NSString *which in s[@"shots"]) {   // Images first: the check may change the state.
            NSString *name = [NSString stringWithFormat:@"%@-%@-%@", s[@"id"], which, gChinese ? @"zh" : @"en"];
            NSView *v = [self viewFor:which]; if (!v) continue;
            gSnapshot = YES; [self shot:name view:v]; gSnapshot = NO; [v setNeedsDisplay:YES]; [self.app.surface setNeedsDisplay:YES];
            [files addObject:[name stringByAppendingString:@".png"]];
        }
        NSString *failure = ((NSString *(^)(AppDelegate *))s[@"check"])(self.app);
        BOOL ok = failure == nil, blocked = [failure hasPrefix:@"BLOCKED:"];
        NSString *status = ok ? @"PASS" : blocked ? @"BLOCKED" : @"FAIL";
        printf("%s %s %s%s%s\n", status.UTF8String, [s[@"id"] UTF8String], [s[@"desc"] UTF8String], ok ? "" : " :: ", ok ? "" : failure.UTF8String); fflush(stdout);
        [self.results addObject:@{@"id": s[@"id"], @"description": s[@"desc"], @"status": status, @"detail": failure ?: @"",
                                  @"screenshots": files, @"appActive": @(NSApp.active), @"keyWindow": NSApp.keyWindow.title ?: @"(none)"}];
        [self saveResults];
        self.index++; [self runNext];
    });
}
- (void)finish {
    [self.app.overlay dismissAnimated:NO];
    NSDictionary *after = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier ?: @"?"];
    BOOL same = (self.realPrefsBefore == nil && after == nil) || [self.realPrefsBefore isEqualToDictionary:after];
    [self.results addObject:@{@"id": @"UI-PV", @"description": @"Live UI test did not change the real FocusCard preferences", @"status": same ? @"PASS" : @"FAIL", @"detail": same ? @"" : @"real domain changed", @"screenshots": @[], @"appActive": @(NSApp.active), @"keyWindow": @""}];
    printf("%s UI-PV real preferences unchanged\n", same ? "PASS" : "FAIL");
    [self saveResults];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:kUISuite];
    gClockOffset = 0;
    int fail = 0; for (NSDictionary *r in self.results) if ([r[@"status"] isEqual:@"FAIL"]) fail++;
    printf("UI SUMMARY lang=%s total=%lu fail=%d\n", gChinese ? "zh" : "en", (unsigned long)self.results.count, fail); fflush(stdout);
    exit(fail ? 1 : 0);
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.realPrefsBefore = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier ?: @"?"];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:kUISuite];
    AppDelegate *a = [AppDelegate new]; self.app = a;
    a.sandboxed = YES; a.defaults = [[NSUserDefaults alloc] initWithSuiteName:kUISuite]; [a loadState];
    [a buildCard]; [a buildMainMenu]; [a buildStatusMenu]; [a refreshForce:YES]; [a updateTicker];
    a.overlay = [CompletionOverlay new]; a.overlay.passThrough = YES;   // The test's synthetic clicks still reach it.
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:a selector:@selector(clockChanged) name:NSWorkspaceDidWakeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:a selector:@selector(clockChanged) name:NSCalendarDayChangedNotification object:nil];
    [a showCard:nil];
    if (@available(macOS 14.0, *)) [NSApp activate]; else [NSApp activateIgnoringOtherApps:YES];
    self.results = [NSMutableArray array]; self.steps = [NSMutableArray array];
    [NSFileManager.defaultManager createDirectoryAtPath:self.dir withIntermediateDirectories:YES attributes:nil error:nil];
    [self defineSteps];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self runNext]; });
}

- (void)defineSteps {
    NSString *(^expect)(BOOL, NSString *) = ^NSString *(BOOL ok, NSString *detail) { return ok ? nil : detail; };
    __block NSRect cardFrame = NSZeroRect; __block NSInteger sessions = 0; __block NSUInteger alerts = 0;
    __block NSWindow *coverWindow = nil;
    NSString *focusWord = T(@"专注", @"Focus"), *breakWord = T(@"休息", @"Break");
    NSString *(^saved)(AppDelegate *) = ^NSString *(AppDelegate *a) { return [a.statusLabel.stringValue hasPrefix:T(@"已保存 · ", @"Saved · ")] && !a.saveButton.enabled ? nil : S(@"status='%@' save=%d", a.statusLabel.stringValue, a.saveButton.enabled); };

    [self step:@"UI-01" desc:@"Launch shows the card and an icon-only status item; the header shows today's rounds" wait:.3 shots:@[@"card", @"status"] action:^(AppDelegate *a) {}
         check:^NSString *(AppDelegate *a) { return expect(a.panel.visible && a.statusItem.button.image && a.statusTitle.length == 0 && [a.timeLabel.stringValue isEqualToString:@"25:00"] && [a.roundsLabel.stringValue isEqualToString:T(@"今日 0 轮", @"0 today")],
                                                         S(@"visible=%d title='%@' time=%@ rounds=%@", a.panel.visible, a.statusTitle, a.timeLabel.stringValue, a.roundsLabel.stringValue)); }];
    [self step:@"UI-02" desc:@"Click the primary button: the timer starts" wait:.3 shots:@[@"card", @"status"] action:^(AppDelegate *a) { postClick(a.startButton); }
         check:^NSString *(AppDelegate *a) { return expect(a.running && a.statusTitle.length == 5 && [a.startButton.title isEqualToString:T(@"暂停", @"Pause")], S(@"running=%d status='%@'", a.running, a.statusTitle)); }];
    [self step:@"UI-03" desc:@"Live ticker updates the card and the menu bar every second" wait:2.4 shots:@[@"card"] action:^(AppDelegate *a) {}
         check:^NSString *(AppDelegate *a) { NSInteger s = [a secondsRemaining]; return expect(s <= 1498 && [a.timeLabel.stringValue isEqualToString:timeString(s)] && [a.statusTitle isEqualToString:timeString(s)],
                                                         S(@"s=%ld label=%@ status=%@", (long)s, a.timeLabel.stringValue, a.statusTitle)); }];
    [self step:@"UI-04" desc:@"Click the primary button again: paused; the card says the time can be double-clicked" wait:.3 shots:@[@"card", @"status"] action:^(AppDelegate *a) { postClick(a.startButton); }
         check:^NSString *(AppDelegate *a) { return expect(a.paused && a.statusDimmed && [a.startButton.title isEqualToString:T(@"继续", @"Resume")] && [a.statusItem.button.image.accessibilityDescription isEqualToString:T(@"已暂停", @"Paused")]
                                                         && [a.stateLabel.stringValue containsString:T(@"双击", @"double-click")], S(@"paused=%d state=%@", a.paused, a.stateLabel.stringValue)); }];
    [self step:@"UI-05" desc:@"Press Space on the card: the timer resumes" wait:.3 shots:@[] action:^(AppDelegate *a) { [a.panel sendEvent:keyEvent(a.panel, @" ", 49, 0)]; }
         check:^NSString *(AppDelegate *a) { return expect(a.running, @"not running after Space"); }];
    [self step:@"UI-06" desc:@"Click Reset: full length, idle, Reset disabled" wait:.3 shots:@[@"card"] action:^(AppDelegate *a) { postClick(a.resetButton); }
         check:^NSString *(AppDelegate *a) { return expect(!a.started && [a.timeLabel.stringValue isEqualToString:@"25:00"] && !a.resetButton.enabled, a.timeLabel.stringValue); }];
    [self step:@"UI-07" desc:@"Click the disabled Reset button: nothing happens" wait:.2 shots:@[] action:^(AppDelegate *a) { postClick(a.resetButton); }
         check:^NSString *(AppDelegate *a) { return expect(!a.started && !a.rest, @"state changed"); }];
    [self step:@"UI-08" desc:@"Click Skip: idle break, cup icon in the menu bar" wait:.3 shots:@[@"card", @"status"] action:^(AppDelegate *a) { postClick(a.skipButton); }
         check:^NSString *(AppDelegate *a) { return expect(a.rest && !a.started && [a.timeLabel.stringValue isEqualToString:@"05:00"] && [a.statusItem.button.image.accessibilityDescription isEqualToString:breakWord],
                                                         S(@"rest=%d icon=%@", a.rest, a.statusItem.button.image.accessibilityDescription)); }];
    [self step:@"UI-09" desc:@"Command-Right Arrow (Timer menu) skips back to focus" wait:.3 shots:@[] action:^(AppDelegate *a) {
            menuKey(a.panel, [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey], 124, NSEventModifierFlagCommand | NSEventModifierFlagFunction | NSEventModifierFlagNumericPad); }
         check:^NSString *(AppDelegate *a) { return expect(!a.rest && [a.statusItem.button.image.accessibilityDescription isEqualToString:focusWord], @"still in break"); }];
    [self step:@"UI-10" desc:@"Command-R while idle does nothing (menu item disabled)" wait:.2 shots:@[] action:^(AppDelegate *a) { menuKey(a.panel, @"r", 15, NSEventModifierFlagCommand); }
         check:^NSString *(AppDelegate *a) { return expect(!a.started && [a secondsRemaining] == 1500, @"state changed"); }];
    [self step:@"UI-11" desc:@"Status menu: choose Start Focus" wait:.3 shots:@[@"status"] action:^(AppDelegate *a) {
            [a menuNeedsUpdate:a.statusMenu]; [a.statusMenu performActionForItemAtIndex:[a.statusMenu indexOfItem:a.menuToggle]]; [a menuNeedsUpdate:a.statusMenu]; }
         check:^NSString *(AppDelegate *a) { return expect(a.running && [a.menuToggle.title isEqualToString:T(@"暂停", @"Pause")] && [a.menuState.title containsString:a.statusTitle], a.menuState.title); }];
    [self step:@"UI-12" desc:@"Command-R while running resets the timer" wait:.3 shots:@[] action:^(AppDelegate *a) { menuKey(a.panel, @"r", 15, NSEventModifierFlagCommand); }
         check:^NSString *(AppDelegate *a) { return expect(!a.started && [a secondsRemaining] == 1500, S(@"started=%d", a.started)); }];
    [self step:@"UI-13" desc:@"Start, then click Hide: the card hides and the timer keeps running" wait:.4 shots:@[@"status"] action:^(AppDelegate *a) { postClick(a.startButton); postClick(a.hideButton); }
         check:^NSString *(AppDelegate *a) { [a menuNeedsUpdate:a.statusMenu]; return expect(!a.panel.visible && a.running && [a.menuCard.title isEqualToString:T(@"显示卡片", @"Show Card")], a.menuCard.title); }];
    [self step:@"UI-14" desc:@"Status menu: Show Card brings the card back" wait:.4 shots:@[@"card"] action:^(AppDelegate *a) { [a.statusMenu performActionForItemAtIndex:[a.statusMenu indexOfItem:a.menuCard]]; }
         check:^NSString *(AppDelegate *a) { [a menuNeedsUpdate:a.statusMenu]; return expect(a.panel.visible && [a.menuCard.title isEqualToString:T(@"隐藏卡片", @"Hide Card")] && a.cardVisible, @"card not visible"); }];
    [self step:@"UI-15" desc:@"Command-W on the card hides it (Window menu)" wait:.4 shots:@[] action:^(AppDelegate *a) { [a.panel makeKeyAndOrderFront:nil]; menuKey(a.panel, @"w", 13, NSEventModifierFlagCommand); }
         check:^NSString *(AppDelegate *a) { NSString *r = NSApp.active ? expect(!a.panel.visible, S(@"still visible; key=%@", NSApp.keyWindow)) : (a.panel.visible ? @"BLOCKED: the test process is not the active app, so no key window receives Command-W" : nil);
                                             [a showCard:nil]; return r; }];
    // --- Settings: draft, Save, Revert ---
    [self step:@"UI-16" desc:@"Click the gear: Settings opens on the Timer pane, everything saved" wait:.6 shots:@[@"settings"] action:^(AppDelegate *a) { postClick(a.settingsButton); }
         check:^NSString *(AppDelegate *a) { return expect(a.settingsWindow.visible && a.currentPane == 0 && [a.focusField.stringValue isEqualToString:@"25"] && !a.saveButton.enabled && ![a settingsDirty],
                                                         S(@"visible=%d pane=%ld save=%d", a.settingsWindow.visible, (long)a.currentPane, a.saveButton.enabled)); }];
    [self step:@"UI-17" desc:@"Type 'abc' in Focus and press Tab: rejected, value kept, red message" wait:.4 shots:@[@"settings"] action:^(AppDelegate *a) {
            [a.settingsWindow makeKeyAndOrderFront:nil]; postClick(a.focusField); menuKey(a.settingsWindow, @"a", 0, NSEventModifierFlagCommand);
            typeKeys(a.settingsWindow, @"abc"); [a.settingsWindow sendEvent:keyEvent(a.settingsWindow, @"\t", 48, 0)]; }
         check:^NSString *(AppDelegate *a) { return expect(a.focusMinutes == 25 && [a.focusField.stringValue isEqualToString:@"25"] && [a.durationNote.textColor isEqual:NSColor.systemRedColor] && [a.durationNote.stringValue containsString:@"abc"] && !a.saveButton.enabled,
                                                         S(@"min=%ld field=%@ note=%@", (long)a.focusMinutes, a.focusField.stringValue, a.durationNote.stringValue)); }];
    [self step:@"UI-18" desc:@"Type full-width '４０' and press Return: the draft shows 1 unsaved change; nothing stored yet" wait:.4 shots:@[@"settings"] action:^(AppDelegate *a) {
            postClick(a.focusField); menuKey(a.settingsWindow, @"a", 0, NSEventModifierFlagCommand);
            typeKeys(a.settingsWindow, @"４０"); [a.settingsWindow sendEvent:keyEvent(a.settingsWindow, @"\r", 36, 0)]; }
         check:^NSString *(AppDelegate *a) { return expect([a.draft[kFocus] integerValue] == 40 && (a.focusMinutes == 25 || a.focusMinutes == 40) && [a.focusField.stringValue isEqualToString:@"40"],
                                                         S(@"draft=%@ min=%ld field=%@ status=%@", a.draft[kFocus], (long)a.focusMinutes, a.focusField.stringValue, a.statusLabel.stringValue)); }];
    [self step:@"UI-19" desc:@"Click the Focus stepper up arrow: 41 in the draft" wait:.4 shots:@[] action:^(AppDelegate *a) {
            NSStepper *st = a.focusStepper; postClickAt(st, NSMakePoint(NSMidX(st.bounds), st.isFlipped ? st.bounds.size.height * .25 : st.bounds.size.height * .75), 1); }
         check:^NSString *(AppDelegate *a) { return expect([a.draft[kFocus] integerValue] == 41 && [a.focusField.stringValue isEqualToString:@"41"] && (a.saveButton.enabled || a.focusMinutes == 41), S(@"draft=%@", a.draft[kFocus])); }];
    [self step:@"UI-20" desc:@"Click Save: stored, 'Saved' with the time, Save disabled, running timer unchanged" wait:.5 shots:@[@"settings"] action:^(AppDelegate *a) { postClick(a.saveButton); }
         check:^NSString *(AppDelegate *a) { NSString *r = saved(a); return r ?: expect(a.focusMinutes == 41 && [a.defaults integerForKey:kFocus] == 41 && a.running && [a secondsRemaining] <= 1500, S(@"min=%ld", (long)a.focusMinutes)); }];
    [self step:@"UI-21" desc:@"Turn on 'Keep above': not applied until Save; Save floats the card" wait:.5 shots:@[] action:^(AppDelegate *a) { press(a.paneButtons[2]); toggleSwitch(a.pinSwitch); }
         check:^NSString *(AppDelegate *a) { BOOL waiting = a.panel.level < NSNormalWindowLevel && [a settingsDirty]; press(a.saveButton); BOOL on = a.panel.level == NSFloatingWindowLevel && a.pinned;
                                             toggleSwitch(a.pinSwitch); press(a.saveButton); BOOL off = a.panel.level < NSNormalWindowLevel && !a.pinned;
                                             NSPoint p = [a.saveButton convertPoint:NSMakePoint(NSMidX(a.saveButton.bounds), NSMidY(a.saveButton.bounds)) toView:nil];
                                             NSView *hit = [a.settingsWindow.contentView.superview hitTest:[a.settingsWindow.contentView.superview convertPoint:p fromView:nil]];
                                             return expect(waiting && on && off, S(@"waiting=%d on=%d off=%d hit=%@ enabled=%d", waiting, on, off, hit.className, a.saveButton.enabled)); }];
    [self step:@"UI-21b" desc:@"An unpinned card stays below a regular window when shown" wait:.4 shots:@[] action:^(AppDelegate *a) {
            coverWindow = [[NSWindow alloc] initWithContentRect:NSInsetRect(a.panel.frame, -20, -20) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            coverWindow.releasedWhenClosed = NO; coverWindow.level = NSNormalWindowLevel;
            [coverWindow orderFrontRegardless]; [a showCard:nil]; }
         check:^NSString *(AppDelegate *a) { return expect(windowIsAbove(coverWindow, a.panel), @"The regular window must cover the unpinned card"); }];
    [self step:@"UI-21c" desc:@"A pinned card is above a regular window in the window server" wait:.4 shots:@[] action:^(AppDelegate *a) {
            saveSetting(a, kPinned, @YES); [a showCard:nil]; }
         check:^NSString *(AppDelegate *a) { return expect(windowIsAbove(a.panel, coverWindow), @"The pinned card must cover the regular window"); }];
    [self step:@"UI-21d" desc:@"Turning pinning off immediately places the card below a regular window" wait:.4 shots:@[] action:^(AppDelegate *a) {
            saveSetting(a, kPinned, @NO); }
         check:^NSString *(AppDelegate *a) { BOOL below = windowIsAbove(coverWindow, a.panel); [coverWindow close]; coverWindow = nil;
            [a.settingsWindow makeKeyAndOrderFront:nil]; return expect(below, @"Saving unpinned mode must lower the card immediately"); }];
    [self step:@"UI-22" desc:@"Appearance: click the Rain theme tile: the card previews it, 1 unsaved change" wait:.6 shots:@[@"settings", @"card"] action:^(AppDelegate *a) {
            ThemeTile *t = nil; for (ThemeTile *x in a.themeTiles) if ([x.theme.key isEqualToString:@"rain"]) t = x; press(t); }
         check:^NSString *(AppDelegate *a) { ThemeTile *t = a.themeTiles[2]; NSPoint p = [t convertPoint:NSMakePoint(NSMidX(t.bounds), NSMidY(t.bounds)) toView:nil];
                                             NSView *hit = [a.settingsWindow.contentView.superview hitTest:[a.settingsWindow.contentView.superview convertPoint:p fromView:nil]];
                                             return expect([a.surface.theme.key isEqualToString:@"rain"] && [a.themeKey isEqualToString:@"aurora"] && [a dirtyKeys].count == 1 && a.settingsWindow.documentEdited,
                                                         S(@"surface=%@ dirty=%@ hit=%@ win=%@ host=%@ sheet=%@", a.surface.theme.key, [[a dirtyKeys] componentsJoinedByString:@","], hit.className,
                                                           NSStringFromRect(a.settingsWindow.frame), NSStringFromRect(a.paneHost.frame), a.settingsWindow.attachedSheet)); }];
    [self step:@"UI-23" desc:@"Click Revert: the card returns to the saved theme" wait:.5 shots:@[] action:^(AppDelegate *a) { press(a.revertButton); }
         check:^NSString *(AppDelegate *a) { return expect([a.surface.theme.key isEqualToString:@"aurora"] && ![a settingsDirty] && !a.revertButton.enabled, a.surface.theme.key); }];
    [self step:@"UI-24" desc:@"Click the Frost tile and Save: light theme on the card, stored" wait:.6 shots:@[@"card", @"settings"] action:^(AppDelegate *a) {
            ThemeTile *t = nil; for (ThemeTile *x in a.themeTiles) if ([x.theme.key isEqualToString:@"frost"]) t = x; press(t); press(a.saveButton); }
         check:^NSString *(AppDelegate *a) { NSString *r = saved(a); return r ?: expect([a.themeKey isEqualToString:@"frost"] && [[a.defaults stringForKey:kTheme] isEqualToString:@"frost"] && [a.panel.appearance.name isEqualToString:NSAppearanceNameAqua], a.themeKey); }];
    [self step:@"UI-25" desc:@"Increase the background slider (accessibility increment x3): preview, then Save" wait:.5 shots:@[@"card"] action:^(AppDelegate *a) {
            for (int i = 0; i < 3; i++) [a.opacitySlider accessibilityPerformIncrement]; }
         check:^NSString *(AppDelegate *a) { double prev = a.surface.opacity; BOOL waiting = fabs(a.glassOpacity - .45) < .001 && prev > .46; press(a.saveButton);
                                             return expect(waiting && a.glassOpacity > .46 && fabs(a.surface.opacity - a.glassOpacity) < .001, S(@"preview=%.2f saved=%.2f", prev, a.glassOpacity)); }];
    [self step:@"UI-26" desc:@"Alerts: choose the 'Hero' sound: it plays as a preview; Save stores it" wait:.5 shots:@[@"settings"] action:^(AppDelegate *a) {
            press(a.paneButtons[1]); choosePopup(a.soundPopup, 2); }
         check:^NSString *(AppDelegate *a) { BOOL previewed = [a.alertLog.lastObject isEqualToString:@"preview=Hero"]; press(a.saveButton);
                                             return expect(previewed && [a.soundName isEqualToString:@"Hero"] && [[a.defaults stringForKey:kSoundName] isEqualToString:@"Hero"], S(@"log=%@ sound=%@", a.alertLog.lastObject, a.soundName)); }];
    [self step:@"UI-27" desc:@"Click the play button: the chosen sound previews again" wait:.3 shots:@[] action:^(AppDelegate *a) { [a.alertLog removeAllObjects]; press(a.previewButton); }
         check:^NSString *(AppDelegate *a) { return expect([a.alertLog.lastObject isEqualToString:@"preview=Hero"], a.alertLog.lastObject ?: @"(none)"); }];
    [self step:@"UI-28" desc:@"Choose 'Notification only': the Timer pane shows the auto-start options; switching back hides them" wait:.5 shots:@[] action:^(AppDelegate *a) { choosePopup(a.completionPopup, 1); }
         check:^NSString *(AppDelegate *a) { BOOL shown = !a.autoStartGroup.hidden; choosePopup(a.completionPopup, 0); BOOL hidden = a.autoStartGroup.hidden;
                                             return expect(shown && hidden && ![a settingsDirty], S(@"shown=%d hidden=%d", shown, hidden)); }];
    [self step:@"UI-29" desc:@"Change a value and press Escape: Settings asks to save; 'Don't Save' closes and discards" wait:.8 shots:@[@"settings"] action:^(AppDelegate *a) {
            press(a.paneButtons[3]); toggleSwitch(a.menuTimeSwitch);
            [a.settingsWindow makeKeyAndOrderFront:nil]; [a.settingsWindow makeFirstResponder:nil]; [a.settingsWindow keyDown:keyEvent(a.settingsWindow, @"\e", 53, 0)]; }
         check:^NSString *(AppDelegate *a) { NSWindow *sheet = a.settingsWindow.attachedSheet; BOOL asked = sheet != nil;
            if (sheet) { NSButton *dont = nil; for (NSView *v in [sheet.contentView subviews]) if ([v isKindOfClass:NSButton.class] && [[(NSButton *)v title] isEqualToString:T(@"不保存", @"Don’t Save")]) dont = (NSButton *)v;
                         if (dont) [dont performClick:nil]; else [a.settingsWindow endSheet:sheet returnCode:NSAlertThirdButtonReturn]; }
            return expect(asked && a.showMenuTime && [a.defaults boolForKey:kMenuTime], S(@"asked=%d menuTime=%d visible=%d", asked, a.showMenuTime, a.settingsWindow.visible)); }];
    [self step:@"UI-30" desc:@"Settings is closed after 'Don't Save'" wait:.5 shots:@[] action:^(AppDelegate *a) {}
         check:^NSString *(AppDelegate *a) { NSString *r = expect(!a.settingsWindow.visible && !a.draft && [a.surface.theme.key isEqualToString:a.themeKey], S(@"visible=%d", a.settingsWindow.visible)); if (a.settingsWindow.visible) [a.settingsWindow orderOut:nil]; return r; }];
    [self step:@"UI-31" desc:@"Command-Comma opens Settings; Command-W closes it (no changes, no question)" wait:.5 shots:@[] action:^(AppDelegate *a) { menuKey(a.panel, @",", 43, NSEventModifierFlagCommand); }
         check:^NSString *(AppDelegate *a) { BOOL opened = a.settingsWindow.visible; menuKey(a.settingsWindow, @"w", 13, NSEventModifierFlagCommand);
                                             if (opened && a.settingsWindow.visible && !NSApp.active) { [a.settingsWindow performClose:nil]; return @"BLOCKED: Settings opened, but the test process is not the active app, so Command-W has no key window"; }
                                             return expect(opened && !a.settingsWindow.visible, S(@"opened=%d closed=%d", opened, !a.settingsWindow.visible)); }];
    [self step:@"UI-31b" desc:@"General: choose the other language and click Save: stored; 'Relaunch Now' appears" wait:.6 shots:@[@"settings"] action:^(AppDelegate *a) {
            [a showSettings:nil]; press(a.paneButtons[3]); choosePopup(a.languagePopup, gChinese ? 2 : 1); press(a.saveButton); }
         check:^NSString *(AppDelegate *a) { NSString *want = gChinese ? @"en" : @"zh";
                                             NSString *r = expect([[a.defaults stringForKey:kLanguage] isEqualToString:want] && !a.relaunchButton.hidden, S(@"stored=%@ relaunchHidden=%d", [a.defaults stringForKey:kLanguage], a.relaunchButton.hidden));
                                             saveSetting(a, kLanguage, @"system"); [a.settingsWindow orderOut:nil]; return r; }];
    // --- Double-click the paused time ---
    [self step:@"UI-32" desc:@"15 rapid clicks on the primary button: final state is consistent" wait:.5 shots:@[@"card"] action:^(AppDelegate *a) {
            [a reset:nil]; for (int i = 0; i < 15; i++) postClick(a.startButton); }
         check:^NSString *(AppDelegate *a) { NSInteger s = [a secondsRemaining]; return expect(a.running && s > 0 && s <= 2460, S(@"running=%d s=%ld", a.running, (long)s)); }];
    [self step:@"UI-33" desc:@"Double-click the time while running: nothing opens" wait:.5 shots:@[] action:^(AppDelegate *a) {
            postClickAt(a.card, NSMakePoint(NSMidX(a.timeLabel.frame), NSMidY(a.timeLabel.frame)), 2); }
         check:^NSString *(AppDelegate *a) { return expect(!a.settingsWindow.visible && a.running, @"settings opened while running"); }];
    [self step:@"UI-34" desc:@"Pause, then double-click the time: Settings opens with the Focus length selected" wait:.7 shots:@[@"settings", @"card"] action:^(AppDelegate *a) {
            postClick(a.startButton); gClockOffset += 60; [a refreshForce:YES]; postClickAt(a.card, NSMakePoint(NSMidX(a.timeLabel.frame), NSMidY(a.timeLabel.frame)), 2); }
         check:^NSString *(AppDelegate *a) { id fr = a.settingsWindow.firstResponder; BOOL focused = fr == a.focusField || ([fr isKindOfClass:NSTextView.class] && [(NSTextView *)fr delegate] == (id)a.focusField);
                                             return expect(a.paused && a.settingsWindow.visible && a.currentPane == 0 && focused, S(@"visible=%d pane=%ld fr=%@", a.settingsWindow.visible, (long)a.currentPane, [fr className])); }];
    __block NSInteger usedBefore = 0;
    [self step:@"UI-35" desc:@"Type 50, click Save: the paused timer keeps the time used and shows the new remaining time" wait:.5 shots:@[@"card"] action:^(AppDelegate *a) {
            usedBefore = (NSInteger)llround(a.sessionDuration - a.countdown.remaining);
            menuKey(a.settingsWindow, @"a", 0, NSEventModifierFlagCommand); typeKeys(a.settingsWindow, @"50"); press(a.saveButton); }
         check:^NSString *(AppDelegate *a) { NSInteger expectLeft = 3000 - usedBefore;
                                             return expect(a.paused && a.focusMinutes == 50 && labs([a secondsRemaining] - expectLeft) <= 1 && a.sessionDuration == 3000, S(@"left=%ld expect=%ld", (long)[a secondsRemaining], (long)expectLeft)); }];
    [self step:@"UI-36" desc:@"Close Settings and resume: the timer counts down from the new time" wait:1.3 shots:@[] action:^(AppDelegate *a) { [a.settingsWindow performClose:nil]; postClick(a.startButton); }
         check:^NSString *(AppDelegate *a) { NSInteger left = [a secondsRemaining]; return expect(a.running && left < 3000 - usedBefore && left > 3000 - usedBefore - 4 && !a.settingsWindow.visible, S(@"left=%ld", (long)left)); }];
    [self step:@"UI-37" desc:@"Double-click the card background: no state change" wait:.3 shots:@[] action:^(AppDelegate *a) { postClick(a.startButton); postClickAt(a.card, NSMakePoint(150, 8), 2); }
         check:^NSString *(AppDelegate *a) { return expect(a.paused && a.panel.visible && !a.settingsWindow.visible, @"state changed"); }];
    // --- Completion prompt ---
    [self step:@"UI-38" desc:@"Focus reaches 00:00 live: full-screen 'Time to Take a Break', sound, counted once, nothing starts" wait:1.8 shots:@[@"prompt", @"card", @"status"] action:^(AppDelegate *a) {
            [a reset:nil]; [a toggle:nil]; sessions = a.statsSessions; alerts = a.alertLog.count; gClockOffset += a.sessionDuration + .3; }
         check:^NSString *(AppDelegate *a) { BOOL covers = a.overlay.windows.count == NSScreen.screens.count && a.overlay.windows.firstObject.visible && a.overlay.windows.firstObject.level > NSStatusWindowLevel;
                                             return expect(a.overlay.visible && covers && a.rest && !a.started && a.statsSessions == sessions + 1 && a.alertLog.count == alerts + 1 && [a.alertLog.lastObject containsString:@"sound=Hero"]
                                                           && [a.overlay.title isEqualToString:T(@"该休息了", @"Time to Take a Break")] && [a.roundsLabel.stringValue isEqualToString:S(T(@"今日 %ld 轮", @"%ld today"), (long)a.statsSessions)],
                                                           S(@"overlay=%d windows=%lu rest=%d started=%d alerts=%lu", a.overlay.visible, (unsigned long)a.overlay.windows.count, a.rest, a.started, (unsigned long)a.alertLog.count)); }];
    [self step:@"UI-39" desc:@"The prompt waits: 3 s later the break has still not started" wait:3 shots:@[] action:^(AppDelegate *a) {}
         check:^NSString *(AppDelegate *a) { return expect(a.overlay.visible && !a.started, S(@"overlay=%d started=%d", a.overlay.visible, a.started)); }];
    [self step:@"UI-40" desc:@"Click 'Start Break': the prompt closes and the 5-minute break runs" wait:.8 shots:@[@"card"] action:^(AppDelegate *a) { postClick(a.overlay.primaryButton); }
         check:^NSString *(AppDelegate *a) { return expect(!a.overlay.visible && a.rest && a.running && [a secondsRemaining] <= 300 && [a secondsRemaining] > 295, S(@"overlay=%d running=%d s=%ld", a.overlay.visible, a.running, (long)[a secondsRemaining])); }];
    [self step:@"UI-41" desc:@"Break ends while the card is hidden: 'Ready to Focus?' prompt; Escape = Not Now; focus waits, card stays hidden" wait:1.8 shots:@[@"prompt"] action:^(AppDelegate *a) {
            [a hideCard:nil]; alerts = a.alertLog.count; gClockOffset += a.sessionDuration + .3; }
         check:^NSString *(AppDelegate *a) { BOOL shown = a.overlay.visible && [a.overlay.title isEqualToString:T(@"准备好专注了吗？", @"Ready to Focus?")];
                                             NSWindow *w = a.overlay.windows.firstObject; [w sendEvent:keyEvent(w, @"\e", 53, 0)];
                                             NSString *r = expect(shown && !a.overlay.visible && !a.rest && !a.started && !a.panel.visible && a.alertLog.count == alerts + 1, S(@"shown=%d overlay=%d rest=%d visible=%d", shown, a.overlay.visible, a.rest, a.panel.visible));
                                             [a showCard:nil]; return r; }];
    [self step:@"UI-42" desc:@"Focus ends again; press Return on the prompt: the break starts" wait:1.8 shots:@[] action:^(AppDelegate *a) { [a toggle:nil]; gClockOffset += a.sessionDuration + .3; }
         check:^NSString *(AppDelegate *a) { BOOL shown = a.overlay.visible; NSWindow *w = a.overlay.windows.firstObject; [w sendEvent:keyEvent(w, @"\r", 36, 0)];
                                             return expect(shown && !a.overlay.visible && a.rest && a.running, S(@"shown=%d overlay=%d running=%d key=%@", shown, a.overlay.visible, a.running, NSApp.keyWindow.className)); }];
    [self step:@"UI-42b" desc:@"Focus ends again; click anywhere on the screen outside the buttons: the prompt closes (Not Now)" wait:1.8 shots:@[] action:^(AppDelegate *a) { [a reset:nil]; if (a.rest) [a skip:nil]; [a toggle:nil]; gClockOffset += a.sessionDuration + .3; }
         check:^NSString *(AppDelegate *a) { BOOL shown = a.overlay.visible; NSWindow *w = a.overlay.windows.lastObject;
                                             if (w) postClickAt(w.contentView, NSMakePoint(40, 40), 1);
                                             return expect(shown && !a.overlay.visible && a.rest && !a.started, S(@"shown=%d overlay=%d rest=%d started=%d", shown, a.overlay.visible, a.rest, a.started)); }];
    [self step:@"UI-43" desc:@"Wake after 2 hours with a running focus: the prompt shows the end time, silently" wait:.8 shots:@[@"prompt"] action:^(AppDelegate *a) {
            [a reset:nil]; if (a.rest) [a skip:nil];
            [a toggle:nil]; alerts = a.alertLog.count; gClockOffset += a.sessionDuration + 7200;
            [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceDidWakeNotification object:NSWorkspace.sharedWorkspace]; }
         check:^NSString *(AppDelegate *a) { NSString *r = expect(a.rest && !a.started && a.alertLog.count == alerts && a.overlay.visible && [a.overlay.subtitle containsString:@":"], a.overlay.subtitle ?: @"(none)");
                                             [a overlaySecondary:nil]; return r; }];
    [self step:@"UI-44" desc:@"Midnight passes while idle (day-changed notification): the header count resets to 0" wait:.5 shots:@[@"card"] action:^(AppDelegate *a) {
            gClockOffset += 86400; [NSNotificationCenter.defaultCenter postNotificationName:NSCalendarDayChangedNotification object:nil]; }
         check:^NSString *(AppDelegate *a) { return expect(a.statsSessions == 0 && [a.roundsLabel.stringValue isEqualToString:T(@"今日 0 轮", @"0 today")], a.roundsLabel.stringValue); }];
    [self step:@"UI-45" desc:@"Accessibility: card buttons expose role and label" wait:.1 shots:@[] action:^(AppDelegate *a) {}
         check:^NSString *(AppDelegate *a) { NSMutableString *bad = [NSMutableString string];
            for (NSButton *b in @[a.startButton, a.resetButton, a.skipButton, a.settingsButton, a.hideButton])
                if (![[b accessibilityRole] isEqualToString:NSAccessibilityButtonRole] || [b accessibilityLabel].length == 0 || !b.isAccessibilityElement) [bad appendFormat:@"%@ role=%@ element=%d;", [b accessibilityLabel], [b accessibilityRole], b.isAccessibilityElement];
            if (![[a.ring accessibilityRole] isEqualToString:NSAccessibilityProgressIndicatorRole] || ![[a.ring accessibilityValue] hasSuffix:@"%"]) [bad appendString:@"ring;"];
            return expect(bad.length == 0, bad); }];
    [self step:@"UI-46" desc:@"Click the compact button: the card animates to the 280 x 144 pt landscape card" wait:.7 shots:@[@"card"] action:^(AppDelegate *a) { [a showCard:nil]; [a reset:nil]; if (a.rest) [a skip:nil]; postClick(a.compactButton); }
         check:^NSString *(AppDelegate *a) { return expect(a.compact && NSEqualSizes(a.card.frame.size, NSMakeSize(kCompactW, kCompactH)) && a.settingsButton.hidden, NSStringFromSize(a.card.frame.size)); }];
    [self step:@"UI-47" desc:@"Compact card: click play, the timer runs and the icon becomes pause" wait:.4 shots:@[@"card"] action:^(AppDelegate *a) { postClick(a.startButton); }
         check:^NSString *(AppDelegate *a) { return expect(a.running && [a.startButton.image.accessibilityDescription isEqualToString:T(@"暂停", @"Pause")], a.startButton.image.accessibilityDescription); }];
    [self step:@"UI-48" desc:@"Click the expand button: the card animates back to 300 x 350 pt, timer unchanged" wait:.7 shots:@[@"card"] action:^(AppDelegate *a) { postClick(a.compactButton); }
         check:^NSString *(AppDelegate *a) { return expect(!a.compact && a.running && NSEqualSizes(a.card.frame.size, NSMakeSize(kCardW, kCardH)) && !a.settingsButton.hidden, NSStringFromSize(a.card.frame.size)); }];
    // --- Themes and ambient motion on screen ---
    [self step:@"UI-49" desc:@"Drizzle theme on screen: ripple motion runs (or stays off with Reduce Motion)" wait:7 shots:@[@"card"] action:^(AppDelegate *a) { saveSetting(a, kTheme, @"rain"); [a.settingsWindow orderOut:nil]; }
         check:^NSString *(AppDelegate *a) { BOOL drift = [a.surface.gradient animationForKey:@"drift"] != nil, spawner = a.surface.spawner != nil;
                                             if (reduceMotion()) return expect(!drift && !spawner, @"motion runs with Reduce Motion on");
                                             BOOL glow = [a.surface.glow animationForKey:@"breathe"] != nil, filled = NSEqualRects(a.surface.gradient.frame, a.surface.bounds) && a.surface.bounds.size.width > 0;
                                             return expect(drift && spawner && glow && filled, S(@"drift=%d spawner=%d glow=%d filled=%d", drift, spawner, glow, filled)); }];
    [self step:@"UI-50" desc:@"Hide the card: ambient motion stops" wait:.4 shots:@[] action:^(AppDelegate *a) { [a hideCard:nil]; }
         check:^NSString *(AppDelegate *a) { NSString *r = expect(a.surface.spawner == nil && [a.surface.gradient animationForKey:@"drift"] == nil, @"motion still running"); [a showCard:nil]; return r; }];
    [self step:@"UI-51" desc:@"Turn ambient motion off and Save: motion stops on the visible card" wait:.4 shots:@[] action:^(AppDelegate *a) { saveSetting(a, kAmbient, @NO); [a.settingsWindow orderOut:nil]; }
         check:^NSString *(AppDelegate *a) { NSString *r = expect(!a.surface.motion && a.surface.spawner == nil && [a.surface.gradient animationForKey:@"drift"] == nil, @"motion still running"); saveSetting(a, kAmbient, @YES); [a.settingsWindow orderOut:nil]; return r; }];
    __block double cpu0 = 0, wall0 = 0;
    [self step:@"PF-00" desc:@"Performance setup: Drizzle theme, running timer, card visible; settle 2 s" wait:2 shots:@[] action:^(AppDelegate *a) { [a reset:nil]; [a showCard:nil]; [a toggle:nil]; }
         check:^NSString *(AppDelegate *a) { return expect(a.running && a.panel.visible, @"not running"); }];
    [self step:@"PF-01" desc:@"Performance: CPU use over 10 s, running timer, Drizzle theme with ambient motion (limit 2%)" wait:10 shots:@[] action:^(AppDelegate *a) {
            cpu0 = cpuSeconds(); wall0 = NSProcessInfo.processInfo.systemUptime; }
         check:^NSString *(AppDelegate *a) { double pct = (cpuSeconds() - cpu0) / (NSProcessInfo.processInfo.systemUptime - wall0) * 100; printf("MEASURE cpu=%.2f%%\n", pct);
            return pct < 2 ? nil : S(@"cpu=%.2f%%", pct); }];
    [self step:@"PF-02a" desc:@"Performance setup: idle, Graphite theme; settle 3 s" wait:3 shots:@[] action:^(AppDelegate *a) { [a reset:nil]; saveSetting(a, kTheme, @"graphite"); [a.settingsWindow orderOut:nil]; }
         check:^NSString *(AppDelegate *a) { return expect(!a.started, @"started"); }];
    [self step:@"PF-02" desc:@"Performance: CPU use over 10 s while idle, Graphite theme (limit 0.5%)" wait:10 shots:@[] action:^(AppDelegate *a) {
            cpu0 = cpuSeconds(); wall0 = NSProcessInfo.processInfo.systemUptime; }
         check:^NSString *(AppDelegate *a) { double pct = (cpuSeconds() - cpu0) / (NSProcessInfo.processInfo.systemUptime - wall0) * 100; printf("MEASURE cpu=%.2f%%\n", pct);
            return pct < .5 ? nil : S(@"cpu=%.2f%%", pct); }];
    [self step:@"PF-02b" desc:@"Performance (diagnostic): CPU use over 10 s while idle with the card hidden" wait:10 shots:@[] action:^(AppDelegate *a) {
            [a hideCard:nil]; cpu0 = cpuSeconds(); wall0 = NSProcessInfo.processInfo.systemUptime; }
         check:^NSString *(AppDelegate *a) { double pct = (cpuSeconds() - cpu0) / (NSProcessInfo.processInfo.systemUptime - wall0) * 100;
            NSInteger visible = 0; for (NSWindow *w in NSApp.windows) if (w.visible) visible++;
            printf("MEASURE cpu-hidden=%.2f%% windows=%ld visible=%ld anims=%s fx=%lu\n", pct, (long)NSApp.windows.count, (long)visible,
                   [[a.surface.gradient animationKeys] componentsJoinedByString:@","].UTF8String ?: "", (unsigned long)a.surface.fx.sublayers.count);
            [a showCard:nil]; return nil; }];
    [self step:@"PF-03" desc:@"Performance: resident memory after the full UI test (limit 120 MB)" wait:.1 shots:@[] action:^(AppDelegate *a) {}
         check:^NSString *(AppDelegate *a) { double mb = residentMB(); printf("MEASURE rss=%.1fMB\n", mb); return mb > 0 && mb < 120 ? nil : S(@"rss=%.1f MB", mb); }];
    [self step:@"UI-52" desc:@"Drag the card background: the card moves" wait:.6 shots:@[] action:^(AppDelegate *a) {
            cardFrame = a.panel.frame; NSPoint p = [a.card convertPoint:NSMakePoint(150, 8) toView:nil]; NSTimeInterval t = NSProcessInfo.processInfo.systemUptime; NSInteger wn = a.panel.windowNumber;
            NSEvent *drag = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged location:NSMakePoint(p.x - 60, p.y - 40) modifierFlags:0 timestamp:t + .05 windowNumber:wn context:nil eventNumber:0 clickCount:1 pressure:1];
            NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSMakePoint(p.x - 60, p.y - 40) modifierFlags:0 timestamp:t + .1 windowNumber:wn context:nil eventNumber:0 clickCount:1 pressure:0];
            NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0 timestamp:t windowNumber:wn context:nil eventNumber:0 clickCount:1 pressure:1];
            [NSApp postEvent:drag atStart:NO]; [NSApp postEvent:up atStart:NO]; [NSApp sendEvent:down]; }
         check:^NSString *(AppDelegate *a) { BOOL moved = !NSEqualPoints(a.panel.frame.origin, cardFrame.origin);
            return moved ? nil : S(@"BLOCKED: synthetic events do not drive the window server drag (origin %@); verify by hand", NSStringFromPoint(a.panel.frame.origin)); }];
}
@end

static void uiTest(NSString *dir) {
    NSApplication *app = NSApplication.sharedApplication;
    static UITestRunner *runner; runner = [UITestRunner new]; runner.dir = dir;
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; app.delegate = runner;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 240 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ puts("UI TEST TIMEOUT"); [runner saveResults]; exit(2); });
    [app run];
}

#pragma mark - Screenshot rendering

static void collectEffects(NSView *v, NSMutableArray *out) { for (NSView *s in v.subviews) { if ([s isKindOfClass:NSVisualEffectView.class] && !s.hidden) [out addObject:s]; collectEffects(s, out); } }
static void writePNG(NSView *view, NSString *path) {
    // Blur views draw a flat gray outside the window server: hide them for the image. Dynamic colors resolve in the view's appearance.
    NSMutableArray *effects = [NSMutableArray array]; collectEffects(view, effects); for (NSView *e in effects) e.hidden = YES;
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
    [view layoutSubtreeIfNeeded]; [view setNeedsDisplay:YES]; [view displayIfNeeded];
    NSSize size = view.bounds.size;   // Render at 2x for Retina-quality evidence.
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:(NSInteger)size.width * 2 pixelsHigh:(NSInteger)size.height * 2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = size;
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    }];
    for (NSView *e in effects) e.hidden = NO;
}
// A neutral "desktop" behind the prompt for the documentation image.
static NSImage *sampleDesktop(NSSize size, BOOL light) {
    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[[NSGradient alloc] initWithStartingColor:light ? hex(0xC9D6E8, 1) : hex(0x1F2A44, 1) endingColor:light ? hex(0xEDE3F2, 1) : hex(0x3B2547, 1)] drawInRect:r angle:-30];
        NSArray *wins = @[[NSValue valueWithRect:NSMakeRect(60, 90, 420, 300)], [NSValue valueWithRect:NSMakeRect(520, 180, 380, 330)], [NSValue valueWithRect:NSMakeRect(300, 40, 300, 120)]];
        for (NSValue *v in wins) {
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:v.rectValue xRadius:12 yRadius:12];
            [(light ? rgb(1, 1, 1, .85) : rgb(.16, .17, .2, .95)) setFill]; [p fill];
            NSRect bar = v.rectValue; bar.origin.y = NSMaxY(bar) - 28; bar.size.height = 28;
            [(light ? rgb(.9, .9, .92, 1) : rgb(.22, .23, .27, 1)) setFill]; [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:12 yRadius:12] fill];
            for (int i = 0; i < 5; i++) { [(light ? rgb(0, 0, 0, .08) : rgb(1, 1, 1, .08)) setFill]; NSRectFill(NSMakeRect(NSMinX(v.rectValue) + 24, NSMaxY(v.rectValue) - 60 - i * 26, v.rectValue.size.width * (.4 + .1 * (i % 3)), 10)); }
        }
        return YES; }];
}
static void renderPrompt(Theme *th, BOOL nextRest, NSString *path) {
    NSRect frame = NSMakeRect(0, 0, 960, 600);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO; w.appearance = [NSAppearance appearanceNamed:th.light ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    NSView *host = [[NSView alloc] initWithFrame:frame]; w.contentView = host;
    NSImageView *desk = [NSImageView imageViewWithImage:sampleDesktop(frame.size, th.light)]; desk.frame = frame; desk.imageScaling = NSImageScaleAxesIndependently; [host addSubview:desk];
    NSView *veil = [[NSView alloc] initWithFrame:frame]; [host addSubview:veil];   // Stands in for the full-screen blur in the image.
    Plate *blurStandIn = [[Plate alloc] initWithFrame:frame]; blurStandIn.fill = th.light ? rgb(1, 1, 1, .45) : rgb(0, 0, 0, .35); blurStandIn.radius = 0; [veil addSubview:blurStandIn];
    CompletionOverlay *o = [CompletionOverlay new];
    o.title = nextRest ? T(@"该休息了", @"Time to Take a Break") : T(@"准备好专注了吗？", @"Ready to Focus?");
    o.subtitle = nextRest ? T(@"今天第 3 轮专注已完成。离开屏幕，休息 5 分钟。", @"Focus session 3 of today is done. Step away for 5 minutes.") : T(@"休息结束。下一轮专注 25 分钟。", @"Break is over. Next: 25 minutes of focus.");
    o.primaryTitle = nextRest ? T(@"开始休息 · 5 分钟", @"Start Break · 5 min") : T(@"开始专注 · 25 分钟", @"Start Focus · 25 min");
    o.secondaryTitle = T(@"稍后", @"Not Now");
    NSView *root = [o backdropWithTheme:th rest:nextRest frame:frame];
    for (NSView *v in root.subviews.copy) if ([v isKindOfClass:NSVisualEffectView.class]) [v removeFromSuperview];
    [host addSubview:root];
    [o buildPromptIn:root theme:th rest:nextRest hint:T(@"按 Return 开始 · 点击任意处或按 Esc 稍后", @"Return to start · Click anywhere or Esc for later")];
    writePNG(host, path);
}
static void renderScreens(NSString *dir) {
    [NSApplication sharedApplication];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *lang = gChinese ? @"zh" : @"en";
    NSString *(^P)(NSString *) = ^(NSString *n) { return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.png", n, lang]]; };
    gClockOffset = 0; gSnapshot = YES;
    AppDelegate *a = makeApp(freshSuite());
    a.statsSessions = 3; a.statsFocusSeconds = 4500; [a refreshForce:YES];
    writePNG(a.card, P(@"card-idle"));
    [a toggle:nil]; gClockOffset += 558; [a refresh]; writePNG(a.card, P(@"card-running"));
    [a toggle:nil]; writePNG(a.card, P(@"card-paused"));
    [a toggle:nil]; gClockOffset += 942.5; [a refresh]; [a overlayPrimary:nil]; gClockOffset += 100; [a refresh]; writePNG(a.card, P(@"card-break-running"));
    gClockOffset += 200.5; [a refresh]; [a overlaySecondary:nil]; writePNG(a.card, P(@"card-after-break"));
    saveSetting(a, kFocus, @180); writePNG(a.card, P(@"card-180"));
    saveSetting(a, kFocus, @25);
    for (Theme *t in allThemes()) {   // Each theme: a running focus card and a running break card.
        saveSetting(a, kTheme, t.key); [a reset:nil]; if (a.rest) [a skip:nil];
        [a toggle:nil]; gClockOffset += 739; [a refresh]; writePNG(a.card, P([@"theme-focus-" stringByAppendingString:t.key]));
        [a skip:nil]; [a toggle:nil]; gClockOffset += 61; [a refresh]; writePNG(a.card, P([@"theme-break-" stringByAppendingString:t.key]));
        [a reset:nil]; [a skip:nil];
    }
    saveSetting(a, kTheme, @"aurora");
    [a toggleCompact:nil]; writePNG(a.card, P(@"compact-idle"));
    [a toggle:nil]; gClockOffset += 312; [a refresh]; writePNG(a.card, P(@"compact-running"));
    [a toggle:nil]; writePNG(a.card, P(@"compact-paused"));
    [a reset:nil]; [a skip:nil]; [a toggle:nil]; gClockOffset += 95; [a refresh]; writePNG(a.card, P(@"compact-break"));
    saveSetting(a, kTheme, @"frost"); writePNG(a.card, P(@"compact-frost"));
    saveSetting(a, kTheme, @"aurora");
    [a reset:nil]; [a skip:nil]; [a toggleCompact:nil];
    // Settings panes and states.
    NSView *frame = a.settingsWindow.contentView.superview ?: a.settingsWindow.contentView;
    NSArray *names = @[@"settings-timer", @"settings-alerts", @"settings-appearance", @"settings-general"];
    for (NSInteger p = 0; p < 4; p++) { [a showSettingsPane:p focusDuration:NO]; [a.settingsWindow makeFirstResponder:nil]; writePNG(frame, P(names[p])); }
    [a showSettingsPane:2 focusDuration:NO]; [a.settingsWindow makeFirstResponder:nil];
    for (ThemeTile *t in a.themeTiles) if ([t.theme.key isEqualToString:@"water"]) [a themeChosen:t];
    a.pinSwitch.state = NSControlStateValueOn; [a switchChanged:a.pinSwitch];
    writePNG(frame, P(@"settings-unsaved")); writePNG(a.card, P(@"card-preview-water"));
    [a saveDraft]; writePNG(frame, P(@"settings-saved"));
    saveSetting(a, kTheme, @"aurora"); saveSetting(a, kPinned, @NO);
    [a showSettingsPane:0 focusDuration:NO]; [a.settingsWindow makeFirstResponder:nil];
    [a durationEditedText:@"abc" rest:NO]; a.focusField.stringValue = @"abc";
    [a controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:a.focusField]]; writePNG(frame, P(@"settings-error"));
    [a revertSettings:nil];
    saveSetting(a, kCompletion, kBanner); [a showSettingsPane:0 focusDuration:NO]; [a.settingsWindow makeFirstResponder:nil]; writePNG(frame, P(@"settings-timer-banner"));
    saveSetting(a, kCompletion, kOverlay);
    // Paused card with the edit hint, then the prompt screens.
    [a toggle:nil]; gClockOffset += 600; [a toggle:nil]; writePNG(a.card, P(@"card-paused-edit"));
    renderPrompt(themeNamed(@"aurora"), YES, P(@"prompt-break"));
    renderPrompt(themeNamed(@"aurora"), NO, P(@"prompt-focus"));
    renderPrompt(themeNamed(@"frost"), YES, P(@"prompt-break-frost"));
    renderPrompt(themeNamed(@"dusk"), NO, P(@"prompt-focus-dusk"));
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:kSuite];
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 256, 256)];
    iconView.image = [NSImage imageWithSize:NSMakeSize(256, 256) flipped:NO drawingHandler:^BOOL(NSRect r) { drawIcon(r); return YES; }];
    writePNG(iconView, [dir stringByAppendingPathComponent:@"app-icon.png"]);
    gSnapshot = NO;
    printf("Rendered screenshots to %s (%s)\n", dir.UTF8String, lang.UTF8String);
}

#pragma mark - Command line

static void notificationStatus(void) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
            NSMutableArray *titles = [NSMutableArray array];
            for (UNNotification *n in notifications) [titles addObject:n.request.content.title];
            NSDictionary *result = @{@"authorization": @(settings.authorizationStatus), @"deliveredCount": @(notifications.count), @"titles": titles};
            puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);
            dispatch_semaphore_signal(done);
        }];
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) puts("Notification status unavailable");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        detectLanguage([NSUserDefaults.standardUserDefaults stringForKey:@"language"]);
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) { selfTest(argc > 2 ? @(argv[2]) : nil); return gFail ? 1 : 0; }
        if (argc > 2 && strcmp(argv[1], "--ui-test") == 0) { if (argc > 3) gChinese = strcmp(argv[3], "en") != 0; uiTest(@(argv[2])); return 0; }
        if (argc > 2 && strcmp(argv[1], "--render-screenshots") == 0) { renderScreens(@(argv[2])); return 0; }
        if (argc > 2 && strcmp(argv[1], "--export-icons") == 0) { exportIcons(@(argv[2])); return 0; }
        if (argc > 1 && strcmp(argv[1], "--notification-status") == 0) { notificationStatus(); return 0; }
        NSApplication *app = NSApplication.sharedApplication;
        static AppDelegate *delegate; delegate = [AppDelegate new];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; app.delegate = delegate; [app run];
    }
    return 0;
}
