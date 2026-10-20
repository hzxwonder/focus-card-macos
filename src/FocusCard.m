#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <UserNotifications/UserNotifications.h>
#import <assert.h>
#import <math.h>

typedef struct { double remaining, deadline; } Countdown;
static NSInteger secondsLeft(Countdown c, double now) { return MAX(0, (NSInteger)ceil(c.deadline > 0 ? c.deadline-now : c.remaining)); }
static void startTimer(Countdown *c, double now) { if (!c->deadline && c->remaining > 0) c->deadline = now+c->remaining; }
static void pauseTimer(Countdown *c, double now) { if (c->deadline) c->remaining = MAX(0, c->deadline-now); c->deadline=0; }
static BOOL finishTimer(Countdown *c, double now) {
    if (!c->deadline || c->deadline>now) return NO;
    c->remaining=c->deadline=0; return YES;
}
static NSInteger boundedMinutes(NSInteger value, NSInteger fallback) { return value>=1 && value<=180 ? value : fallback; }
static NSColor *rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
static NSColor *accent(BOOL rest) { return rest ? rgb(.29,.94,.79,1) : rgb(.62,.77,1,1); }
static NSColor *muted(void) { return rgb(.92,.95,1,1); }
static NSString *timeString(NSInteger seconds) { return [NSString stringWithFormat:@"%02ld:%02ld",(long)seconds/60,(long)seconds%60]; }

static void hourglass(NSRect rect, NSColor *color) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t=[NSAffineTransform transform]; [t translateXBy:rect.origin.x yBy:rect.origin.y]; [t scaleXBy:rect.size.width/100 yBy:rect.size.height/100]; [t concat];
    NSBezierPath *p=[NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(24,90)]; [p lineToPoint:NSMakePoint(76,90)];
    [p curveToPoint:NSMakePoint(59,52) controlPoint1:NSMakePoint(76,70) controlPoint2:NSMakePoint(73,66)];
    [p curveToPoint:NSMakePoint(76,10) controlPoint1:NSMakePoint(76,34) controlPoint2:NSMakePoint(76,30)];
    [p lineToPoint:NSMakePoint(24,10)];
    [p curveToPoint:NSMakePoint(41,52) controlPoint1:NSMakePoint(24,30) controlPoint2:NSMakePoint(24,34)];
    [p curveToPoint:NSMakePoint(24,90) controlPoint1:NSMakePoint(27,66) controlPoint2:NSMakePoint(24,70)]; [p closePath];
    p.lineWidth=7; p.lineJoinStyle=NSLineJoinStyleRound; [color setStroke]; [p stroke];
    NSBezierPath *sand=[NSBezierPath bezierPath];
    [sand moveToPoint:NSMakePoint(36,22)]; [sand lineToPoint:NSMakePoint(64,22)]; [sand lineToPoint:NSMakePoint(50,39)]; [sand closePath];
    [color setFill]; [sand fill];
    [NSGraphicsContext restoreGraphicsState];
}
static void drawIcon(NSRect rect) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t=[NSAffineTransform transform]; [t translateXBy:rect.origin.x yBy:rect.origin.y]; [t scaleXBy:rect.size.width/1024 yBy:rect.size.height/1024]; [t concat];
    NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(36,36,952,952) xRadius:220 yRadius:220];
    NSGradient *g=[[NSGradient alloc] initWithStartingColor:rgb(.08,.15,.34,1) endingColor:rgb(.28,.38,.85,1)]; [g drawInBezierPath:shape angle:48];
    NSBezierPath *orbit=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(178,178,668,668)];
    orbit.lineWidth=12; [rgb(.36,.94,.91,.70) setStroke]; [orbit stroke];
    NSBezierPath *halo=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(145,145,734,734)];
    halo.lineWidth=2; [rgb(.64,.84,1,.26) setStroke]; [halo stroke];
    hourglass(NSMakeRect(300,278,424,468),NSColor.whiteColor);
    [rgb(.61,1,.92,1) setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(771,718,39,39)] fill];
    NSBezierPath *border=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(38,38,948,948) xRadius:218 yRadius:218];
    border.lineWidth=3; [rgb(1,1,1,.25) setStroke]; [border stroke];
    [NSGraphicsContext restoreGraphicsState];
}
static NSImage *brandImage(CGFloat size) {
    return [NSImage imageWithSize:NSMakeSize(size,size) flipped:NO drawingHandler:^BOOL(NSRect rect) { drawIcon(rect); return YES; }];
}
static NSImage *menuImage(void) {
    NSImage *image=[NSImage imageWithSize:NSMakeSize(18,18) flipped:NO drawingHandler:^BOOL(NSRect rect) { hourglass(NSInsetRect(rect,1,1),NSColor.blackColor); return YES; }];
    image.template=YES; return image;
}
static void exportIcons(NSString *directory) {
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *names=@[@"icon_16x16.png",@"icon_16x16@2x.png",@"icon_32x32.png",@"icon_32x32@2x.png",@"icon_128x128.png",@"icon_128x128@2x.png",@"icon_256x256.png",@"icon_256x256@2x.png",@"icon_512x512.png",@"icon_512x512@2x.png"];
    NSArray *sizes=@[@16,@32,@32,@64,@128,@256,@256,@512,@512,@1024];
    for (NSUInteger i=0;i<names.count;i++) {
        NSInteger size=[sizes[i] integerValue];
        NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:size pixelsHigh:size bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        drawIcon(NSMakeRect(0,0,size,size)); [NSGraphicsContext restoreGraphicsState];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[directory stringByAppendingPathComponent:names[i]] atomically:YES];
    }
}

@interface CardWindow : NSWindow @end
@implementation CardWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end
@interface PassiveLabel : NSTextField @end
@implementation PassiveLabel
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end
@interface GlassSurface : NSView
@property double opacity;
@property BOOL rest;
@end
@implementation GlassSurface
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)rect {
    BOOL solid=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    CGFloat alpha=solid ? .97 : .54+self.opacity*.38;
    NSGradient *g=[[NSGradient alloc] initWithStartingColor:rgb(.08,.16,.34,alpha) endingColor:self.rest ? rgb(.05,.30,.30,alpha) : rgb(.20,.20,.44,alpha)];
    [g drawInBezierPath:[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:28 yRadius:28] angle:-45];
    NSBezierPath *edge=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.65,.65) xRadius:27.5 yRadius:27.5];
    edge.lineWidth=1.3; [rgb(1,1,1,.27) setStroke]; [edge stroke];
}
@end
@interface CardView : NSView @end
@implementation CardView
- (void)mouseDown:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if (p.y>self.bounds.size.height-64) [self.window performWindowDragWithEvent:event]; else [super mouseDown:event];
}
@end
@interface GlowButton : NSButton
@property BOOL primary;
@property BOOL rest;
@property BOOL hovered;
@property NSTrackingArea *tracking;
@end
@implementation GlowButton
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking=[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingActiveAlways|NSTrackingMouseEnteredAndExited|NSTrackingInVisibleRect owner:self userInfo:nil]; [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)event { self.hovered=YES; self.needsDisplay=YES; }
- (void)mouseExited:(NSEvent *)event { self.hovered=NO; self.needsDisplay=YES; }
- (void)drawRect:(NSRect)rect {
    NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:13 yRadius:13];
    if(self.primary) {
        NSGradient *g=[[NSGradient alloc] initWithStartingColor:self.rest ? rgb(.45,.98,.84,1) : rgb(.72,.83,1,1) endingColor:self.rest ? rgb(.25,.78,.76,1) : rgb(.46,.64,1,1)]; [g drawInBezierPath:shape angle:0];
    } else { [rgb(1,1,1,self.hovered ? .19 : .10) setFill]; [shape fill]; }
    if(self.highlighted) { [rgb(0,0,0,.12) setFill]; [shape fill]; }
    if(self.hovered) { [rgb(1,1,1,.08) setFill]; [shape fill]; }
    NSColor *text=self.primary ? rgb(.07,.13,.25,1) : NSColor.whiteColor;
    if(self.image) {
        [text setFill];
        NSRect area=NSMakeRect((self.bounds.size.width-17)/2,(self.bounds.size.height-17)/2,17,17);
        CGContextRef context=NSGraphicsContext.currentContext.CGContext;
        CGContextBeginTransparencyLayer(context,NULL);
        [self.image drawInRect:area fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        [text setFill]; NSRectFillUsingOperation(area,NSCompositingOperationSourceIn);
        CGContextEndTransparencyLayer(context);
    } else {
        NSDictionary *attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:text};
        NSSize size=[self.title sizeWithAttributes:attrs]; [self.title drawAtPoint:NSMakePoint((self.bounds.size.width-size.width)/2,(self.bounds.size.height-size.height)/2) withAttributes:attrs];
    }
    if(self.window.firstResponder==self) { [accent(self.rest) setStroke]; shape.lineWidth=2; [shape stroke]; }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate,NSWindowDelegate,UNUserNotificationCenterDelegate,NSMenuDelegate,NSTextFieldDelegate>
@property CardWindow *panel;
@property CardView *card;
@property GlassSurface *surface;
@property NSVisualEffectView *effect;
@property NSTextField *timeLabel,*stateLabel,*nextLabel,*phaseLabel;
@property GlowButton *startButton,*resetButton;
@property NSSegmentedControl *mode;
@property CAShapeLayer *progressLayer;
@property NSStatusItem *statusItem;
@property NSMenuItem *menuState,*menuToggle;
@property NSUserDefaults *defaults;
@property NSTimer *ticker;
@property Countdown countdown;
@property NSInteger focusMinutes,breakMinutes,lastSeconds;
@property double sessionDuration,glassOpacity;
@property BOOL rest,started,autoBreak,autoFocus,notifications,sound,pinned;
@property NSString *completionText;
@property UNAuthorizationStatus authorization;
@property NSWindow *settingsWindow;
@property NSTextField *focusField,*breakField,*permissionLabel,*validationLabel;
@property NSStepper *focusStepper,*breakStepper;
@property NSButton *autoBreakBox,*autoFocusBox,*notificationBox,*soundBox,*pinBox;
@property NSSlider *opacitySlider;
@end
@implementation AppDelegate
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size color:(NSColor *)color parent:(NSView *)parent {
    NSTextField *label=[PassiveLabel labelWithString:text]; label.frame=frame; label.font=[NSFont systemFontOfSize:size]; label.textColor=color; [parent addSubview:label]; return label;
}
- (GlowButton *)button:(NSString *)title frame:(NSRect)frame action:(SEL)action primary:(BOOL)primary {
    GlowButton *button=[[GlowButton alloc] initWithFrame:frame]; button.title=title; button.primary=primary; button.bordered=NO; button.target=self; button.action=action; button.rest=self.rest; [self.card addSubview:button]; return button;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.defaults=NSUserDefaults.standardUserDefaults;
    [self.defaults registerDefaults:@{@"minutes":@25,@"breakMinutes":@5,@"autoBreak":@YES,@"autoFocus":@NO,@"notifications":@YES,@"sound":@YES,@"pinned":@YES,@"glassOpacity":@.45}];
    self.focusMinutes=boundedMinutes([self.defaults integerForKey:@"minutes"],25); self.breakMinutes=boundedMinutes([self.defaults integerForKey:@"breakMinutes"],5);
    self.rest=[self.defaults boolForKey:@"rest"]; self.started=[self.defaults boolForKey:@"started"];
    self.autoBreak=[self.defaults boolForKey:@"autoBreak"]; self.autoFocus=[self.defaults boolForKey:@"autoFocus"];
    self.notifications=[self.defaults boolForKey:@"notifications"]; self.sound=[self.defaults boolForKey:@"sound"]; self.pinned=[self.defaults boolForKey:@"pinned"];
    self.glassOpacity=MAX(.1,MIN(.9,[self.defaults doubleForKey:@"glassOpacity"]));
    self.sessionDuration=[self.defaults doubleForKey:@"sessionDuration"];
    if(self.sessionDuration<=0) self.sessionDuration=(self.rest ? self.breakMinutes : self.focusMinutes)*60;
    double remaining=[self.defaults objectForKey:@"remaining"] ? [self.defaults doubleForKey:@"remaining"] : self.sessionDuration;
    self.countdown=(Countdown){MAX(0,remaining),[self.defaults doubleForKey:@"endTime"]};
    if(self.countdown.deadline>0 || remaining<self.sessionDuration) self.started=YES;
    self.lastSeconds=-1;
    [UNUserNotificationCenter currentNotificationCenter].delegate=self;
    [self buildCard]; [self buildMenu]; [self readAuthorization];
    [self refresh];
    self.ticker=[NSTimer timerWithTimeInterval:.25 target:self selector:@selector(refresh) userInfo:nil repeats:YES]; self.ticker.tolerance=.05; [NSRunLoop.mainRunLoop addTimer:self.ticker forMode:NSRunLoopCommonModes];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(refresh) name:NSWorkspaceDidWakeNotification object:nil];
    [self showCard:nil];
}
- (void)buildCard {
    self.card=[[CardView alloc] initWithFrame:NSMakeRect(0,0,336,338)]; self.card.wantsLayer=YES; self.card.layer.cornerRadius=28; self.card.layer.masksToBounds=YES;
    self.effect=[[NSVisualEffectView alloc] initWithFrame:self.card.bounds]; self.effect.material=NSVisualEffectMaterialHUDWindow; self.effect.blendingMode=NSVisualEffectBlendingModeBehindWindow; self.effect.state=NSVisualEffectStateActive; self.effect.alphaValue=.35; [self.card addSubview:self.effect];
    self.surface=[[GlassSurface alloc] initWithFrame:self.card.bounds]; self.surface.opacity=self.glassOpacity; self.surface.rest=self.rest; [self.card addSubview:self.surface];
    self.panel=[[CardWindow alloc] initWithContentRect:self.card.bounds styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    self.panel.title=@"专注卡片"; self.panel.opaque=NO; self.panel.backgroundColor=NSColor.clearColor; self.panel.hasShadow=YES; self.panel.releasedWhenClosed=NO; self.panel.canHide=NO;
    self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.level=self.pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
    self.panel.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; self.panel.contentView=self.card; self.panel.delegate=self;
    NSImageView *logo=[[NSImageView alloc] initWithFrame:NSMakeRect(22,286,27,27)]; logo.image=brandImage(27); [self.card addSubview:logo];
    NSTextField *title=[self label:@"专注卡片" frame:NSMakeRect(58,291,170,21) size:14 color:NSColor.whiteColor parent:self.card]; title.font=[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    title.toolTip=@"拖动标题区域移动卡片";
    GlowButton *settings=[self button:@"" frame:NSMakeRect(280,282,34,34) action:@selector(showSettings:) primary:NO]; settings.image=[NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:@"设置"]; [settings setAccessibilityLabel:@"打开设置"]; settings.toolTip=@"设置";
    self.mode=[NSSegmentedControl segmentedControlWithLabels:@[@"专注",@"休息"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeMode:)];
    self.mode.frame=NSMakeRect(82,239,172,28); self.mode.segmentStyle=NSSegmentStyleRounded; self.mode.selectedSegment=self.rest?1:0; [self.card addSubview:self.mode];
    self.timeLabel=[self label:@"25:00" frame:NSMakeRect(14,146,308,84) size:66 color:NSColor.whiteColor parent:self.card];
    self.timeLabel.font=[NSFont monospacedDigitSystemFontOfSize:66 weight:NSFontWeightLight]; self.timeLabel.alignment=NSTextAlignmentCenter;
    self.stateLabel=[self label:@"准备开始" frame:NSMakeRect(24,126,288,21) size:12 color:muted() parent:self.card]; self.stateLabel.alignment=NSTextAlignmentCenter;
    CAShapeLayer *track=[CAShapeLayer layer]; CGPathRef path=CGPathCreateWithRoundedRect(CGRectMake(24,104,288,4),2,2,NULL); track.path=path; track.fillColor=rgb(1,1,1,.12).CGColor; [self.card.layer addSublayer:track]; CGPathRelease(path);
    self.progressLayer=[CAShapeLayer layer]; self.progressLayer.fillColor=accent(self.rest).CGColor; [self.card.layer addSublayer:self.progressLayer];
    self.startButton=[self button:@"开始专注" frame:NSMakeRect(23,43,235,43) action:@selector(toggle:) primary:YES]; self.startButton.keyEquivalent=@" "; self.startButton.keyEquivalentModifierMask=0;
    self.resetButton=[self button:@"" frame:NSMakeRect(269,43,44,43) action:@selector(reset:) primary:NO]; self.resetButton.image=[NSImage imageWithSystemSymbolName:@"arrow.counterclockwise" accessibilityDescription:@"重新计时"]; [self.resetButton setAccessibilityLabel:@"重新计时"]; self.resetButton.toolTip=@"重新计时";
    self.nextLabel=[self label:@"下一段 · 休息 5 分钟" frame:NSMakeRect(20,14,296,18) size:11 color:muted() parent:self.card]; self.nextLabel.alignment=NSTextAlignmentCenter;
    NSRect screen=NSScreen.mainScreen.visibleFrame;
    [self.panel setFrameAutosaveName:@"FocusCardPositionV2"];
    if(![self.panel setFrameUsingName:@"FocusCardPositionV2"]) [self.panel setFrameOrigin:NSMakePoint(NSMinX(screen)+28,NSMaxY(screen)-660)];
    // The card keeps a fixed layout when restoring a frame from a different screen.
    [self.panel setContentSize:self.card.frame.size];
}
- (void)buildMenu {
    NSMenu *main=[[NSMenu alloc] init]; NSMenuItem *application=[[NSMenuItem alloc] init]; [main addItem:application];
    NSMenu *applicationMenu=[[NSMenu alloc] initWithTitle:@"专注卡片"];
    NSMenuItem *preferences=[applicationMenu addItemWithTitle:@"设置…" action:@selector(showSettings:) keyEquivalent:@","]; preferences.target=self;
    [applicationMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *exit=[applicationMenu addItemWithTitle:@"退出专注卡片" action:@selector(terminate:) keyEquivalent:@"q"]; exit.target=NSApp;
    application.submenu=applicationMenu; NSApp.mainMenu=main;
    self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image=menuImage(); self.statusItem.button.imagePosition=NSImageLeft;
    self.statusItem.button.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    NSMenu *menu=[[NSMenu alloc] init]; menu.delegate=self;
    self.menuState=[menu addItemWithTitle:@"专注 · 25:00" action:nil keyEquivalent:@""];
    NSMenuItem *show=[menu addItemWithTitle:@"显示卡片" action:@selector(showCard:) keyEquivalent:@""]; show.target=self;
    self.menuToggle=[menu addItemWithTitle:@"开始专注" action:@selector(toggle:) keyEquivalent:@""]; self.menuToggle.target=self;
    NSMenuItem *reset=[menu addItemWithTitle:@"重新计时" action:@selector(reset:) keyEquivalent:@""]; reset.target=self;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings=[menu addItemWithTitle:@"设置…" action:@selector(showSettings:) keyEquivalent:@","]; settings.target=self;
    NSMenuItem *hide=[menu addItemWithTitle:@"隐藏卡片" action:@selector(hideCard:) keyEquivalent:@""]; hide.target=self;
    [menu addItem:NSMenuItem.separatorItem]; NSMenuItem *quit=[menu addItemWithTitle:@"退出专注卡片" action:@selector(terminate:) keyEquivalent:@"q"]; quit.target=NSApp;
    self.statusItem.menu=menu;
}
- (void)menuNeedsUpdate:(NSMenu *)menu { [self refresh]; }
- (void)showCard:(id)sender {
    BOOL onScreen=NO;
    for(NSScreen *screen in NSScreen.screens) if(NSIntersectsRect(self.panel.frame,NSInsetRect(screen.visibleFrame,40,40))) onScreen=YES;
    if(!onScreen) { NSRect screen=NSScreen.mainScreen.visibleFrame; [self.panel setFrameOrigin:NSMakePoint(NSMinX(screen)+28,NSMaxY(screen)-self.panel.frame.size.height-60)]; }
    [NSApp unhide:nil]; [self.panel makeKeyAndOrderFront:nil]; [self.panel orderFrontRegardless];
}
- (void)hideCard:(id)sender { [self.panel orderOut:nil]; }
- (BOOL)windowShouldClose:(NSWindow *)sender {
    if(sender==self.settingsWindow) { self.surface.opacity=self.glassOpacity; self.surface.needsDisplay=YES; }
    [sender orderOut:nil]; return NO;
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible { [self showCard:nil]; return YES; }
- (void)windowDidMove:(NSNotification *)notification { if(notification.object==self.panel) [self.panel saveFrameUsingName:@"FocusCardPositionV2"]; }
- (void)save {
    NSDictionary *values=@{@"minutes":@(self.focusMinutes),@"breakMinutes":@(self.breakMinutes),@"rest":@(self.rest),@"started":@(self.started),@"remaining":@(self.countdown.remaining),@"endTime":@(self.countdown.deadline),@"sessionDuration":@(self.sessionDuration),@"autoBreak":@(self.autoBreak),@"autoFocus":@(self.autoFocus),@"notifications":@(self.notifications),@"sound":@(self.sound),@"pinned":@(self.pinned),@"glassOpacity":@(self.glassOpacity)};
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key,id value,BOOL *stop){ [self.defaults setObject:value forKey:key]; }];
}
- (void)refresh {
    Countdown c=self.countdown; double now=NSDate.date.timeIntervalSince1970;
    if(finishTimer(&c,now)) {
        BOOL finishedRest=self.rest;
        NSString *title=finishedRest ? @"休息结束，准备好下一轮了吗？" : @"专注完成，让眼睛和身体放松一下";
        [self notifyTitle:title body:finishedRest ? @"回到卡片，开始下一轮专注。" : [NSString stringWithFormat:@"接下来休息 %ld 分钟。",(long)self.breakMinutes]];
        self.rest=!finishedRest; self.sessionDuration=(self.rest?self.breakMinutes:self.focusMinutes)*60;
        self.countdown=(Countdown){self.sessionDuration,0}; self.started=NO;
        self.completionText=finishedRest?@"休息完成 · 开始新的专注":@"专注完成 · 好好休息一下";
        if(self.rest ? self.autoBreak : self.autoFocus) { c=self.countdown; startTimer(&c,now); self.countdown=c; self.started=YES; }
        [self save]; self.lastSeconds=-1;
    }
    NSInteger seconds=secondsLeft(self.countdown,now);
    if(seconds==self.lastSeconds) return;
    self.lastSeconds=seconds; BOOL running=self.countdown.deadline>0;
    NSString *phase=self.rest?@"休息":@"专注";
    self.timeLabel.stringValue=timeString(seconds); [self.timeLabel setAccessibilityLabel:[NSString stringWithFormat:@"%@剩余 %ld 分 %ld 秒",phase,(long)seconds/60,(long)seconds%60]];
    self.stateLabel.stringValue=running ? (self.rest?@"放松一下，灵感正在回来的路上":@"把这一刻，留给重要的事") : self.started ? @"已暂停 · 随时继续" : self.completionText ?: @"准备好，进入你的节奏";
    self.startButton.title=running?@"暂停":self.started?@"继续计时":self.rest?@"开始休息":@"开始专注";
    self.startButton.rest=self.rest; self.startButton.needsDisplay=YES;
    self.mode.selectedSegment=self.rest?1:0; self.mode.enabled=!running;
    self.nextLabel.stringValue=[NSString stringWithFormat:@"下一段 · %@ %ld 分钟",self.rest?@"专注":@"休息",(long)(self.rest?self.focusMinutes:self.breakMinutes)];
    self.surface.rest=self.rest; self.surface.needsDisplay=YES;
    double progress=MAX(0,MIN(1,1-seconds/MAX(1,self.sessionDuration)));
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectMake(24,104,288*progress,4),2,2,NULL);
    [CATransaction begin]; [CATransaction setDisableActions:YES]; self.progressLayer.path=path; self.progressLayer.fillColor=accent(self.rest).CGColor; [CATransaction commit]; CGPathRelease(path);
    self.statusItem.button.title=[@" " stringByAppendingString:timeString(seconds)]; self.statusItem.button.appearsDisabled=self.started&&!running;
    self.statusItem.button.toolTip=[NSString stringWithFormat:@"%@ · %@%@",phase,timeString(seconds),self.started&&!running?@" · 已暂停":@""];
    self.menuState.title=[NSString stringWithFormat:@"%@ · %@%@",phase,timeString(seconds),self.started&&!running?@" · 已暂停":@""]; self.menuToggle.title=self.startButton.title;
}
- (void)toggle:(id)sender {
    if(self.countdown.deadline>0 && secondsLeft(self.countdown,NSDate.date.timeIntervalSince1970)==0) [self refresh];
    Countdown c=self.countdown; if(c.deadline>0) pauseTimer(&c,NSDate.date.timeIntervalSince1970); else { startTimer(&c,NSDate.date.timeIntervalSince1970); [self ensureNotifications]; }
    self.countdown=c; self.started=YES; self.completionText=nil; self.lastSeconds=-1; [self refresh]; [self save];
}
- (void)reset:(id)sender {
    self.sessionDuration=(self.rest?self.breakMinutes:self.focusMinutes)*60; self.countdown=(Countdown){self.sessionDuration,0}; self.started=NO; self.completionText=nil; self.lastSeconds=-1; [self refresh]; [self save];
}
- (void)changeMode:(NSSegmentedControl *)sender { self.rest=sender.selectedSegment==1; [self reset:nil]; }
- (void)readAuthorization {
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.authorization=settings.authorizationStatus; [self updatePermissionLabel]; });
    }];
}
- (void)ensureNotifications {
    if(!self.notifications) return;
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:UNAuthorizationOptionAlert|UNAuthorizationOptionSound completionHandler:^(BOOL granted,NSError *error) { [self readAuthorization]; }];
}
- (void)notifyTitle:(NSString *)title body:(NSString *)body {
    if(self.sound) [[NSSound soundNamed:@"Glass"] play];
    if(!self.notifications) return;
    UNMutableNotificationContent *content=[[UNMutableNotificationContent alloc] init]; content.title=title; content.body=body;
    UNNotificationRequest *request=[UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError *error){
        if(error) { NSLog(@"Notification delivery: %@",error); [self readAuthorization]; }
    }];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completion {
    completion(UNNotificationPresentationOptionBanner|UNNotificationPresentationOptionList);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{ [self showCard:nil]; }); completion();
}
- (void)updatePermissionLabel {
    self.permissionLabel.stringValue=self.authorization==UNAuthorizationStatusAuthorized ? @"系统通知已允许" : self.authorization==UNAuthorizationStatusDenied ? @"系统通知未允许，可在系统设置中开启" : @"首次计时会请求系统通知权限";
}
- (NSTextField *)durationField:(NSInteger)value atY:(CGFloat)y parent:(NSView *)view stepper:(NSStepper **)stepper tag:(NSInteger)tag {
    NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(324,y,64,28)]; field.stringValue=[NSString stringWithFormat:@"%ld",(long)value]; field.font=[NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightMedium]; field.alignment=NSTextAlignmentCenter;
    NSNumberFormatter *format=[[NSNumberFormatter alloc] init]; format.numberStyle=NSNumberFormatterDecimalStyle; format.allowsFloats=NO; format.minimum=@1; format.maximum=@180; field.formatter=format; field.delegate=self; [view addSubview:field];
    [self label:@"分钟" frame:NSMakeRect(414,y+4,36,20) size:12 color:NSColor.secondaryLabelColor parent:view];
    NSStepper *step=[[NSStepper alloc] initWithFrame:NSMakeRect(392,y+1,19,27)]; step.minValue=1; step.maxValue=180; step.integerValue=value; step.increment=1; step.valueWraps=NO; step.target=self; step.action=@selector(stepDuration:); step.tag=tag; [view addSubview:step]; *stepper=step; return field;
}
- (NSButton *)checkbox:(NSString *)title y:(CGFloat)y checked:(BOOL)checked parent:(NSView *)view {
    NSButton *box=[NSButton checkboxWithTitle:title target:nil action:nil]; box.frame=NSMakeRect(30,y,430,25); box.state=checked?NSControlStateValueOn:NSControlStateValueOff; [view addSubview:box]; return box;
}
- (void)showSettings:(id)sender {
    if(!self.settingsWindow) {
        self.settingsWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,494,604) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO]; self.settingsWindow.title=@"专注卡片 · 设置"; self.settingsWindow.releasedWhenClosed=NO; self.settingsWindow.delegate=self;
        NSView *view=self.settingsWindow.contentView;
        NSImageView *logo=[[NSImageView alloc] initWithFrame:NSMakeRect(30,536,48,48)]; logo.image=brandImage(48); [view addSubview:logo];
        NSTextField *title=[self label:@"找到你的专注节奏" frame:NSMakeRect(92,558,340,24) size:20 color:NSColor.labelColor parent:view]; title.font=[NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
        [self label:@"让时间安静流动，让每次休息恰到好处。" frame:NSMakeRect(92,536,360,19) size:12 color:NSColor.secondaryLabelColor parent:view];
        NSTextField *section=[self label:@"计时节奏" frame:NSMakeRect(30,496,430,22) size:13 color:NSColor.labelColor parent:view]; section.font=[NSFont boldSystemFontOfSize:13];
        [self label:@"专注时长" frame:NSMakeRect(30,458,270,23) size:13 color:NSColor.labelColor parent:view];
        NSStepper *focusStep; self.focusField=[self durationField:self.focusMinutes atY:455 parent:view stepper:&focusStep tag:0]; self.focusStepper=focusStep; [self.focusField setAccessibilityLabel:@"专注时长，分钟"];
        [self label:@"休息时长" frame:NSMakeRect(30,419,270,23) size:13 color:NSColor.labelColor parent:view];
        NSStepper *breakStep; self.breakField=[self durationField:self.breakMinutes atY:416 parent:view stepper:&breakStep tag:1]; self.breakStepper=breakStep; [self.breakField setAccessibilityLabel:@"休息时长，分钟"];
        self.autoBreakBox=[self checkbox:@"专注结束后自动开始休息" y:377 checked:self.autoBreak parent:view];
        self.autoFocusBox=[self checkbox:@"休息结束后自动开始下一轮专注" y:349 checked:self.autoFocus parent:view];
        section=[self label:@"提醒与外观" frame:NSMakeRect(30,306,430,22) size:13 color:NSColor.labelColor parent:view]; section.font=[NSFont boldSystemFontOfSize:13];
        self.notificationBox=[self checkbox:@"到时发送系统通知" y:274 checked:self.notifications parent:view];
        self.soundBox=[self checkbox:@"播放到时提示音" y:246 checked:self.sound parent:view];
        self.pinBox=[self checkbox:@"卡片始终显示在其他窗口上方" y:218 checked:self.pinned parent:view];
        [self label:@"玻璃背景浓度" frame:NSMakeRect(30,181,150,22) size:13 color:NSColor.labelColor parent:view];
        self.opacitySlider=[NSSlider sliderWithValue:self.glassOpacity minValue:.1 maxValue:.9 target:self action:@selector(previewOpacity:)]; self.opacitySlider.frame=NSMakeRect(190,180,262,25); self.opacitySlider.continuous=YES; [self.opacitySlider setAccessibilityLabel:@"玻璃背景浓度"]; [view addSubview:self.opacitySlider];
        self.permissionLabel=[self label:@"" frame:NSMakeRect(30,140,330,20) size:11 color:NSColor.secondaryLabelColor parent:view];
        NSButton *permission=[NSButton buttonWithTitle:@"通知权限…" target:self action:@selector(notificationPermission:)]; permission.frame=NSMakeRect(356,135,107,28); [view addSubview:permission];
        [self label:@"计时中调整时长，将在下一轮生效。" frame:NSMakeRect(30,105,310,20) size:11 color:NSColor.secondaryLabelColor parent:view];
        NSButton *test=[NSButton buttonWithTitle:@"测试通知" target:self action:@selector(testNotification:)]; test.frame=NSMakeRect(356,98,107,28); [view addSubview:test];
        self.validationLabel=[self label:@"" frame:NSMakeRect(30,79,430,20) size:11 color:NSColor.systemRedColor parent:view];
        NSButton *quit=[NSButton buttonWithTitle:@"退出应用" target:NSApp action:@selector(terminate:)]; quit.frame=NSMakeRect(25,25,104,32); [view addSubview:quit];
        NSButton *cancel=[NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelSettings:)]; cancel.frame=NSMakeRect(275,25,85,32); cancel.keyEquivalent=@"\033"; [view addSubview:cancel];
        NSButton *save=[NSButton buttonWithTitle:@"保存设置" target:self action:@selector(applySettings:)]; save.frame=NSMakeRect(365,25,100,32); save.keyEquivalent=@"\r"; [view addSubview:save];
        [self.settingsWindow center];
    }
    self.focusField.integerValue=self.focusMinutes; self.breakField.integerValue=self.breakMinutes; self.focusStepper.integerValue=self.focusMinutes; self.breakStepper.integerValue=self.breakMinutes;
    self.autoBreakBox.state=self.autoBreak; self.autoFocusBox.state=self.autoFocus; self.notificationBox.state=self.notifications; self.soundBox.state=self.sound; self.pinBox.state=self.pinned; self.opacitySlider.doubleValue=self.glassOpacity; self.validationLabel.stringValue=@"";
    [self readAuthorization]; self.settingsWindow.level=self.panel.level; [NSApp activateIgnoringOtherApps:YES]; [self.settingsWindow makeKeyAndOrderFront:nil];
}
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if(notification.object==self.focusField) self.focusStepper.integerValue=self.focusField.integerValue;
    if(notification.object==self.breakField) self.breakStepper.integerValue=self.breakField.integerValue;
}
- (void)stepDuration:(NSStepper *)sender { if(sender.tag==0) self.focusField.integerValue=sender.integerValue; else self.breakField.integerValue=sender.integerValue; }
- (void)previewOpacity:(NSSlider *)sender { self.surface.opacity=sender.doubleValue; self.surface.needsDisplay=YES; }
- (void)notificationPermission:(id)sender {
    if(self.authorization==UNAuthorizationStatusDenied) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Notifications-Settings.extension"]];
    else [self ensureNotifications];
}
- (void)testNotification:(id)sender {
    if(self.authorization!=UNAuthorizationStatusAuthorized) { [self ensureNotifications]; return; }
    [self notifyTitle:@"专注卡片提醒已就绪" body:@"专注与休息结束时，会在这里提醒你。"];
}
- (void)cancelSettings:(id)sender { self.surface.opacity=self.glassOpacity; self.surface.needsDisplay=YES; [self.settingsWindow orderOut:nil]; }
- (void)applySettings:(id)sender {
    if(![self.settingsWindow makeFirstResponder:nil]) { self.validationLabel.stringValue=@"请输入 1–180 之间的整数分钟数。"; return; }
    NSInteger focus=self.focusField.integerValue, rest=self.breakField.integerValue;
    if(focus<1||focus>180||rest<1||rest>180) { self.validationLabel.stringValue=@"专注与休息时长都应为 1–180 分钟。"; return; }
    self.focusMinutes=focus; self.breakMinutes=rest; self.autoBreak=self.autoBreakBox.state==NSControlStateValueOn; self.autoFocus=self.autoFocusBox.state==NSControlStateValueOn;
    self.notifications=self.notificationBox.state==NSControlStateValueOn; self.sound=self.soundBox.state==NSControlStateValueOn; self.pinned=self.pinBox.state==NSControlStateValueOn;
    self.glassOpacity=self.opacitySlider.doubleValue; self.surface.opacity=self.glassOpacity; self.surface.needsDisplay=YES; self.panel.level=self.pinned?NSFloatingWindowLevel:NSNormalWindowLevel;
    if(!self.started) [self reset:nil]; else { self.lastSeconds=-1; [self refresh]; }
    [self save]; if(self.notifications) [self ensureNotifications]; [self.settingsWindow orderOut:nil]; [self showCard:nil];
}
- (void)applicationWillTerminate:(NSNotification *)notification { [self save]; [self.defaults synchronize]; }
@end

static void selfTest(void) {
    Countdown c={1500,0}; assert(secondsLeft(c,1000)==1500); startTimer(&c,1000); assert(secondsLeft(c,1061)==1439);
    startTimer(&c,1061); assert(c.deadline==2500); pauseTimer(&c,1061.5); assert(secondsLeft(c,2000)==1439);
    startTimer(&c,2000); assert(secondsLeft(c,2001)==1438); Countdown restored=c; assert(secondsLeft(restored,2600)==839);
    assert(finishTimer(&c,4000)); assert(secondsLeft(c,4000)==0); assert(!finishTimer(&c,4001));
    c=(Countdown){300,0}; startTimer(&c,5000); assert(secondsLeft(c,5060)==240); assert(finishTimer(&c,5300));
    c=(Countdown){1500,0}; assert(secondsLeft(c,9999)==1500);
    assert(boundedMinutes(0,25)==25 && boundedMinutes(181,5)==5 && boundedMinutes(1,25)==1);
    assert([timeString(65) isEqualToString:@"01:05"] && [timeString(10800) isEqualToString:@"180:00"]);
    AppDelegate *model=[[AppDelegate alloc] init]; model.focusMinutes=25; model.breakMinutes=5;
    model.autoBreak=YES; model.autoFocus=NO; model.sessionDuration=1500; model.lastSeconds=-1;
    model.countdown=(Countdown){1500,NSDate.date.timeIntervalSince1970-1}; [model refresh];
    assert(model.rest && model.started && secondsLeft(model.countdown,NSDate.date.timeIntervalSince1970)==300);
    Countdown once=model.countdown; [model refresh]; assert(model.countdown.deadline==once.deadline);
    model.countdown=(Countdown){300,NSDate.date.timeIntervalSince1970-1}; [model refresh];
    assert(!model.rest && !model.started && model.countdown.deadline==0 && model.countdown.remaining==1500);
    model.rest=YES; model.autoFocus=YES; model.countdown=(Countdown){300,NSDate.date.timeIntervalSince1970-1}; [model refresh];
    assert(!model.rest && model.started && model.countdown.deadline>NSDate.date.timeIntervalSince1970);
    [model toggle:nil]; assert(model.countdown.deadline==0); [model reset:nil]; assert(!model.started && model.countdown.remaining==1500);
    puts("PASS: focus/rest timing, pause/resume, restoration, single completion, ranges, menu formatting");
}
static void notificationStatus(void) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    UNUserNotificationCenter *center=UNUserNotificationCenter.currentNotificationCenter;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
            NSMutableArray *titles=[NSMutableArray array];
            for(UNNotification *notification in notifications) [titles addObject:notification.request.content.title];
            NSDictionary *result=@{@"authorization":@(settings.authorizationStatus),@"deliveredCount":@(notifications.count),@"titles":titles};
            NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            dispatch_semaphore_signal(done);
        }];
    }];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))) puts("Notification status unavailable");
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc>1 && strcmp(argv[1],"--self-test")==0) { selfTest(); return 0; }
        if(argc>2 && strcmp(argv[1],"--export-icons")==0) { exportIcons(@(argv[2])); return 0; }
        if(argc>1 && strcmp(argv[1],"--notification-status")==0) { notificationStatus(); return 0; }
        NSApplication *app=NSApplication.sharedApplication; static AppDelegate *delegate; delegate=[[AppDelegate alloc] init]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; app.delegate=delegate; [app run];
    } return 0;
}
