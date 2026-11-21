#import "AppDelegate.h"
#import "MainWindowController.h"

// ── Settings window ─────────────────────────────────────────────────────────
@interface EMU3SettingsController : NSWindowController
@property (nonatomic, weak) MainWindowController *mainWC;
@property (nonatomic, strong) NSTextField *folderLabel;
@end

@implementation EMU3SettingsController

- (instancetype)initWithMainWC:(MainWindowController *)wc {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 170)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Settings";
    w.releasedWhenClosed = NO;
    self = [super initWithWindow:w];
    if (!self) return nil;
    _mainWC = wc;
    NSView *c = w.contentView;

    NSButton *tips = [NSButton checkboxWithTitle:@"Show tooltips" target:self action:@selector(_tipsToggled:)];
    tips.state = EMU3TooltipsEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    tips.frame = NSMakeRect(20, 122, 300, 20);
    EMU3Tip(tips, @"Show a short explanation when the pointer rests on a button or control.");

    NSTextField *fl = [NSTextField labelWithString:@"Image folder:"];
    fl.frame = NSMakeRect(20, 84, 90, 18);
    self.folderLabel = [NSTextField labelWithString:@""];
    self.folderLabel.frame = NSMakeRect(112, 84, 250, 18);
    self.folderLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.folderLabel.textColor = NSColor.secondaryLabelColor;
    NSButton *choose = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(_chooseFolder:)];
    choose.bezelStyle = NSBezelStyleRounded;
    choose.frame = NSMakeRect(372, 78, 90, 28);
    EMU3Tip(choose, @"Choose the folder with your disk images (a disk or a NAS share works). The background helper mounts every .hda and .iso in it, and New Image saves there.");
    EMU3Tip(self.folderLabel, @"The folder the background helper watches for disk images.");
    NSTextField *hint = [NSTextField wrappingLabelWithString:@"Images in the image folder are mounted automatically at login as volumes under ~/EMU3 Disks."];
    hint.font = [NSFont systemFontOfSize:11]; hint.textColor = NSColor.secondaryLabelColor;
    hint.frame = NSMakeRect(20, 24, 440, 44);
    for (NSView *v in @[tips, fl, self.folderLabel, choose, hint]) [c addSubview:v];
    [w center];
    return self;
}

- (void)showWindow:(id)sender {
    self.folderLabel.stringValue = self.mainWC.imageFolderURL.path ?: @"";
    [super showWindow:sender];
}

- (void)_tipsToggled:(NSButton *)b {
    [NSUserDefaults.standardUserDefaults setBool:(b.state == NSControlStateValueOn) forKey:@"EMU3TooltipsEnabled"];
    EMU3ApplyTooltipSetting();
}

- (void)_chooseFolder:(id)sender {
    [self.mainWC chooseImageFolder:sender];
    self.folderLabel.stringValue = self.mainWC.imageFolderURL.path ?: @"";
}

@end

// Methods of the main window controller that the app delegate calls (implemented in MainWindowController.m).
@interface MainWindowController (AppDelegateAccess)
- (void)_ensureSamplerLink;
- (void)unmountAllVolumes;
@end

@interface AppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) MainWindowController *mainWC;
@property (nonatomic, strong) EMU3SettingsController *settingsWC;
// Files handed to us by Finder before the main window exists (app not running yet)
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingOpenPaths;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.mainWC = [[MainWindowController alloc] init];
    [self.mainWC showWindow:nil];
    [self.mainWC performSelector:@selector(_ensureSamplerLink)];
    [self _buildMenuBar];

    // Open files that arrived from Finder before the window was ready
    for (NSString *pending in self.pendingOpenPaths) {
        [self.mainWC openImageAtURL:[NSURL fileURLWithPath:pending]];
    }
    self.pendingOpenPaths = nil;

    // Accept a file path as a command-line argument (for testing / CLI launch)
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    if (args.count > 1) {
        NSString *path = args[1];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [self.mainWC openImageAtURL:[NSURL fileURLWithPath:path]];
        }
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    return YES;
}

- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename {
    if (!self.mainWC) {
        // Called before applicationDidFinishLaunching: — remember the file for later.
        if (!self.pendingOpenPaths) self.pendingOpenPaths = [NSMutableArray array];
        [self.pendingOpenPaths addObject:filename];
        return YES;
    }
    [self.mainWC openImageAtURL:[NSURL fileURLWithPath:filename]];
    return YES;
}

- (void)_buildMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    // App menu
    NSMenuItem *appItem = [mainMenu addItemWithTitle:@"EMU3 Disk Manager" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"EMU3 Disk Manager"];
    NSMenuItem *aboutItem = [appMenu addItemWithTitle:@"About EMU3 Disk Manager"
                                               action:@selector(_showAbout:) keyEquivalent:@""];
    aboutItem.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *settingsItem = [appMenu addItemWithTitle:@"Settings…" action:@selector(_showSettings:) keyEquivalent:@","];
    settingsItem.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    // Quit: target = nil → goes via responder chain to NSApplication
    [appMenu addItemWithTitle:@"Quit EMU3 Disk Manager"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    // Edit menu
    NSMenuItem *editItem = [mainMenu addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    editMenu.autoenablesItems = NO;

    NSMenuItem *undoItem = [editMenu addItemWithTitle:@"Undo"
                                             action:@selector(undo:)
                                      keyEquivalent:@"z"];
    undoItem.target = self;

    NSMenuItem *redoItem = [editMenu addItemWithTitle:@"Redo"
                                             action:@selector(redo:)
                                      keyEquivalent:@"Z"];
    redoItem.target = self;

    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *deleteItem = [editMenu addItemWithTitle:@"Delete"
                                               action:@selector(deleteSelectedItem:)
                                        keyEquivalent:@""];
    deleteItem.target = self;

    editMenu.delegate = self;
    editItem.submenu = editMenu;

    NSMenuItem *viewItem = [mainMenu addItemWithTitle:@"View" action:nil keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *expandItem = [viewMenu addItemWithTitle:@"Expand All Folders"
                                                 action:@selector(expandAllInTree:)
                                          keyEquivalent:@"="];
    expandItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    expandItem.target = self;
    NSMenuItem *collapseItem = [viewMenu addItemWithTitle:@"Collapse All Folders"
                                                   action:@selector(collapseAllInTree:)
                                            keyEquivalent:@"-"];
    collapseItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    collapseItem.target = self;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSArray *sortTitles = @[@"Sort Tree A → Z", @"Sort Tree Z → A", @"Sort Tree by Mount Order"];
    for (NSInteger i = 0; i < 3; i++) {
        NSMenuItem *si = [viewMenu addItemWithTitle:sortTitles[i] action:@selector(setTreeSort:) keyEquivalent:@""];
        si.tag = i; si.target = self;
    }
    viewItem.submenu = viewMenu;

    NSMenuItem *toolsItem = [mainMenu addItemWithTitle:@"Tools" action:nil keyEquivalent:@""];
    NSMenu *toolsMenu = [[NSMenu alloc] initWithTitle:@"Tools"];
    NSMenuItem *lnk = [toolsMenu addItemWithTitle:@"Sampler Link (Live USB Disk)…" action:@selector(_showSamplerLink:) keyEquivalent:@"k"];
    lnk.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    lnk.target = self;
    NSMenuItem *mnt = [toolsMenu addItemWithTitle:@"Mount Image as Volume (Finder)" action:@selector(_mountImageAsVolume:) keyEquivalent:@"m"];
    mnt.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    mnt.target = self;
    NSMenuItem *umnt = [toolsMenu addItemWithTitle:@"Unmount Image Volume" action:@selector(_unmountImageVolume:) keyEquivalent:@""];
    umnt.target = self;
    NSMenuItem *smp = [toolsMenu addItemWithTitle:@"Sampler Mode (Lock Images)" action:@selector(_toggleSamplerMode:) keyEquivalent:@"l"];
    smp.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    smp.target = self;
    [toolsMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *newImg = [toolsMenu addItemWithTitle:@"New Image…" action:@selector(_newImage:) keyEquivalent:@"n"];
    newImg.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    newImg.target = self;
    NSMenuItem *chk = [toolsMenu addItemWithTitle:@"Check SD Card…" action:@selector(_checkSDCard:) keyEquivalent:@""];
    chk.target = self;
    NSMenuItem *sdf = [toolsMenu addItemWithTitle:@"Format SD Card…" action:@selector(_formatSDCard:) keyEquivalent:@""];
    sdf.target = self;
    NSMenuItem *fmt = [toolsMenu addItemWithTitle:@"Format Image…" action:@selector(_formatImage:) keyEquivalent:@""];
    fmt.target = self;
    NSMenuItem *ej = [toolsMenu addItemWithTitle:@"Unmount & Eject Card…" action:@selector(_ejectCard:) keyEquivalent:@"e"];
    ej.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    ej.target = self;
    [toolsMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *ini = [toolsMenu addItemWithTitle:@"Create bluescsi.ini…" action:@selector(_createBlueSCSIIni:) keyEquivalent:@""];
    ini.target = self;
    NSMenuItem *fwu = [toolsMenu addItemWithTitle:@"Update Board Firmware…" action:@selector(_updateBoardFirmware:) keyEquivalent:@""];
    fwu.target = self;
    EMU3Tip(lnk, @"Serve an image to the sampler over the BlueSCSI board and watch what the link does.");
    EMU3Tip(mnt, @"Show the selected image as a volume in Finder.");
    EMU3Tip(smp, @"Lock the images so nothing changes them while the sampler works.");
    EMU3Tip(newImg, @"Create an empty, sampler-formatted disk image, 8 MB to 512 GB.");
    EMU3Tip(ini, @"Write a minimal bluescsi.ini for an SD card in the board: SCSI ID, disk size and the USB switch. Not needed without a card.");
    EMU3Tip(fwu, @"Flash a BlueSCSI firmware file (.uf2) onto the board. The sampler loses its disk for about 15 seconds.");
    toolsItem.submenu = toolsMenu;

    NSApp.mainMenu = mainMenu;
}

// The system adds Writing Tools, AutoFill and Emoji & Symbols to the Edit menu; take them out just before it opens.
- (void)menuWillOpen:(NSMenu *)menu {
    if (![menu.title isEqualToString:@"Edit"]) return;
    NSArray<NSString *> *drop = @[@"Writing Tools", @"AutoFill", @"Autofill", @"Emoji & Symbols", @"Emoji &amp; Symbols"];
    for (NSInteger i = (NSInteger)menu.numberOfItems - 1; i >= 0; i--) {
        NSMenuItem *it = [menu itemAtIndex:i];
        BOOL kill = it.action == @selector(orderFrontCharacterPalette:);
        for (NSString *w in drop) if ([it.title hasPrefix:w]) kill = YES;
        if (kill) [menu removeItemAtIndex:i];
    }
    for (NSInteger i = (NSInteger)menu.numberOfItems - 1; i >= 0; i--) {   // no doubled or trailing separators
        NSMenuItem *it = [menu itemAtIndex:i];
        if (it.separatorItem && (i == (NSInteger)menu.numberOfItems - 1 || (i > 0 && [menu itemAtIndex:i - 1].separatorItem)))
            [menu removeItemAtIndex:i];
    }
}

- (void)_updateBoardFirmware:(id)sender {
    [self.mainWC performSelector:@selector(_updateBoardFirmware:) withObject:sender];
}

- (void)_createBlueSCSIIni:(id)sender {
    [self.mainWC performSelector:@selector(_createBlueSCSIIni:) withObject:sender];
}

- (void)_showSettings:(id)sender {
    if (!self.settingsWC) self.settingsWC = [[EMU3SettingsController alloc] initWithMainWC:self.mainWC];
    [self.settingsWC showWindow:nil];
}

- (void)_newImage:(id)sender {
    [self.mainWC performSelector:@selector(_newImage:) withObject:sender];
}

- (void)_toggleSamplerMode:(id)sender {
    [self.mainWC performSelector:@selector(_toggleSamplerMode:) withObject:sender];
}

- (void)_showSamplerLink:(id)sender {
    [self.mainWC performSelector:@selector(_showSamplerLink:) withObject:sender];
}
- (void)_mountImageAsVolume:(id)sender {
    [self.mainWC performSelector:@selector(_mountImageAsVolume:) withObject:sender];
}
- (void)_unmountImageVolume:(id)sender {
    [self.mainWC performSelector:@selector(_unmountImageVolume:) withObject:sender];
}
- (void)applicationWillTerminate:(NSNotification *)n {
    [self.mainWC performSelector:@selector(unmountAllVolumes)];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // The sampler's disk is served by the background helper, so quitting the app does not interrupt it.
    return NSTerminateNow;
}

- (void)_ejectCard:(id)sender {
    [self.mainWC performSelector:@selector(_ejectCard:) withObject:sender];
}

- (void)_formatSDCard:(id)sender {
    [self.mainWC performSelector:@selector(_formatSDCard:) withObject:sender];
}

- (void)_checkSDCard:(id)sender {
    [self.mainWC performSelector:@selector(_checkSDCard:) withObject:sender];
}

- (void)_formatImage:(id)sender {
    [self.mainWC performSelector:@selector(_formatImage:) withObject:sender];
}

- (void)_openImage:(id)sender {
    // Delegate to main window controller's toolbar action via NSApplication's sendAction mechanism
    [self.mainWC performSelector:@selector(_openImage:) withObject:sender];
}

- (void)setTreeSort:(NSMenuItem *)sender {
    [self.mainWC performSelector:@selector(setTreeSort:) withObject:sender];
}

- (void)expandAllInTree:(id)sender {
    [self.mainWC performSelector:@selector(expandAllInTree:) withObject:sender];
}

- (void)collapseAllInTree:(id)sender {
    [self.mainWC performSelector:@selector(collapseAllInTree:) withObject:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(expandAllInTree:) || item.action == @selector(collapseAllInTree:))
        return self.mainWC != nil;
    if (item.action == @selector(_toggleSamplerMode:))
        return [self.mainWC validateUserInterfaceItem:item];
    if (item.action == @selector(_formatImage:))
        return [self.mainWC validateUserInterfaceItem:item];
    if (item.action == @selector(setTreeSort:)) {
        NSInteger mode = [[self.mainWC valueForKeyPath:@"mountedImagesCtl.sortMode"] integerValue];
        item.state = item.tag == mode ? NSControlStateValueOn : NSControlStateValueOff;
        return self.mainWC != nil;
    }
    return YES;
}

- (void)undo:(id)sender {
    [self.mainWC undo:sender];
}

- (void)redo:(id)sender {
    [self.mainWC redo:sender];
}

- (void)deleteSelectedItem:(id)sender {
    [self.mainWC deleteSelectedItem:sender];
}

- (void)_showAbout:(id)sender {
    // Custom panel — NSAlert always forces its own layout, so we build our own.
    // Layout (y measured from bottom of content area, panel height = 450):
    //
    //  ┌─────────────────────────────┐  ← top
    //  │       [App Icon 90×90]      │  y=310
    //  │         Rhyno Audio         │  y=288  (link)
    //  │    EMU3 Disk Manager        │  y=260  (bold 17)
    //  │      Built with Claude      │  y=239  (link, small)
    //  │                             │
    //  │  Browse, copy, move…        │  y=152  (description, wrapped)
    //  │                             │
    //  │  Filesystem format based on:│  y=112  (text view with links)
    //  │  dagargo/emu3fs · dagargo…  │
    //  │                             │
    //  │          [ OK ]             │  y=14
    //  └─────────────────────────────┘

    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 380, 450)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"About EMU3 Disk Manager";
    [panel center];
    NSView *v = panel.contentView;

    // ── Version/Build label ──────────────────────────────────────────────────
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"1";
    NSTextField *versionLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"version %@ build %@", version, build]];
    versionLabel.font = [NSFont systemFontOfSize:9];
    versionLabel.textColor = [NSColor secondaryLabelColor];
    versionLabel.alignment = NSTextAlignmentCenter;
    versionLabel.frame = NSMakeRect(20, 430, 340, 14);
    [v addSubview:versionLabel];

    // ── App icon ─────────────────────────────────────────────────────────────
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(145, 340, 90, 90)];
    iv.image = [NSImage imageNamed:NSImageNameApplicationIcon];
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    [v addSubview:iv];

    // ── Helper: centred attributed string paragraph style ────────────────────
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;

    // ── Rhyno Audio link ─────────────────────────────────────────────────────
    NSTextView *rhynoTV = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 318, 340, 18)];
    rhynoTV.drawsBackground = NO; rhynoTV.editable = NO; rhynoTV.selectable = YES;
    NSMutableAttributedString *rhynoAS = [[NSMutableAttributedString alloc] init];
    [rhynoAS appendAttributedString:[[NSAttributedString alloc] initWithString:@"Rhyno Audio"
        attributes:@{NSFontAttributeName:           [NSFont systemFontOfSize:12],
                     NSForegroundColorAttributeName: [NSColor linkColor],
                     NSLinkAttributeName:            @"https://www.rhyno-audio.net",
                     NSParagraphStyleAttributeName:  ps}]];
    [rhynoTV.textStorage setAttributedString:rhynoAS];
    [v addSubview:rhynoTV];

    // ── App title ─────────────────────────────────────────────────────────────
    NSTextField *titleLbl = [NSTextField labelWithString:@"EMU3 Disk Manager"];
    titleLbl.font      = [NSFont boldSystemFontOfSize:17];
    titleLbl.alignment = NSTextAlignmentCenter;
    titleLbl.frame     = NSMakeRect(10, 290, 360, 24);
    [v addSubview:titleLbl];

    // ── Built with Claude link ────────────────────────────────────────────────
    NSTextView *claudeTV = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 269, 340, 17)];
    claudeTV.drawsBackground = NO; claudeTV.editable = NO; claudeTV.selectable = YES;
    NSMutableAttributedString *claudeAS = [[NSMutableAttributedString alloc] init];
    [claudeAS appendAttributedString:[[NSAttributedString alloc] initWithString:@"Built with Claude"
        attributes:@{NSFontAttributeName:           [NSFont systemFontOfSize:11],
                     NSForegroundColorAttributeName: [NSColor linkColor],
                     NSLinkAttributeName:            @"https://claude.ai",
                     NSParagraphStyleAttributeName:  ps}]];
    [claudeTV.textStorage setAttributedString:claudeAS];
    [v addSubview:claudeTV];

    // ── Description ──────────────────────────────────────────────────────────
    NSTextField *desc = [NSTextField wrappingLabelWithString:
        @"Browse, copy, move, and delete E-MU Emulator III / "
        @"Emulator IV / ESI-32 sampler banks and presets on "
        @"BlueSCSI .hda disk images."];
    desc.font      = [NSFont systemFontOfSize:11];
    desc.textColor = [NSColor secondaryLabelColor];
    desc.alignment = NSTextAlignmentCenter;
    desc.frame     = NSMakeRect(20, 190, 340, 72);
    [v addSubview:desc];

    // ── DiskJockey link for creating .hda images ─────────────────────────────
    NSTextField *djLabel = [NSTextField labelWithString:@"More on .hda disk images"];
    djLabel.font = [NSFont systemFontOfSize:10];
    djLabel.textColor = [NSColor secondaryLabelColor];
    djLabel.alignment = NSTextAlignmentCenter;
    djLabel.frame = NSMakeRect(20, 187, 340, 14);
    [v addSubview:djLabel];

    NSTextView *djTV = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 171, 340, 14)];
    djTV.drawsBackground = NO; djTV.editable = NO; djTV.selectable = YES;
    NSMutableAttributedString *djAS = [[NSMutableAttributedString alloc] init];
    [djAS appendAttributedString:[[NSAttributedString alloc] initWithString:@"DiskJockey"
        attributes:@{NSFontAttributeName:           [NSFont systemFontOfSize:11],
                     NSForegroundColorAttributeName: [NSColor linkColor],
                     NSLinkAttributeName:            @"https://diskjockey.onegeekarmy.eu",
                     NSParagraphStyleAttributeName:  ps}]];
    [djTV.textStorage setAttributedString:djAS];
    [v addSubview:djTV];

    // ── Visit BlueSCSI label and link ────────────────────────────────────────
    NSTextField *visitLabel = [NSTextField labelWithString:@"Visit BlueSCSI"];
    visitLabel.font = [NSFont systemFontOfSize:10];
    visitLabel.textColor = [NSColor secondaryLabelColor];
    visitLabel.alignment = NSTextAlignmentCenter;
    visitLabel.frame = NSMakeRect(20, 145, 340, 14);
    [v addSubview:visitLabel];

    NSTextView *bsTV = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 129, 340, 14)];
    bsTV.drawsBackground = NO; bsTV.editable = NO; bsTV.selectable = YES;
    NSMutableAttributedString *bsAS = [[NSMutableAttributedString alloc] init];
    [bsAS appendAttributedString:[[NSAttributedString alloc] initWithString:@"bluescsi.com"
        attributes:@{NSFontAttributeName:           [NSFont systemFontOfSize:11],
                     NSForegroundColorAttributeName: [NSColor linkColor],
                     NSLinkAttributeName:            @"https://bluescsi.com",
                     NSParagraphStyleAttributeName:  ps}]];
    [bsTV.textStorage setAttributedString:bsAS];
    [v addSubview:bsTV];

    // ── Support link ──────────────────────────────────────────────────────────
    NSTextField *supLabel = [NSTextField labelWithString:@"Free and open source. If it saved you time:"];
    supLabel.font = [NSFont systemFontOfSize:10];
    supLabel.textColor = [NSColor secondaryLabelColor];
    supLabel.alignment = NSTextAlignmentCenter;
    supLabel.frame = NSMakeRect(20, 103, 340, 14);
    [v addSubview:supLabel];

    NSTextView *supTV = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 87, 340, 14)];
    supTV.drawsBackground = NO; supTV.editable = NO; supTV.selectable = YES;
    NSMutableAttributedString *supAS = [[NSMutableAttributedString alloc] init];
    [supAS appendAttributedString:[[NSAttributedString alloc] initWithString:@"Buy me a coffee ☕"
        attributes:@{NSFontAttributeName:           [NSFont systemFontOfSize:11],
                     NSForegroundColorAttributeName: [NSColor linkColor],
                     NSLinkAttributeName:            @"https://www.paypal.com/donate/?hosted_button_id=92QGBZBYGBBXY",
                     NSParagraphStyleAttributeName:  ps}]];
    [supTV.textStorage setAttributedString:supAS];
    [v addSubview:supTV];

    // ── Filesystem links ──────────────────────────────────────────────────────
    NSMutableParagraphStyle *psTight = [ps mutableCopy];
    psTight.paragraphSpacing = 4;

    NSDictionary *greyAttr = @{NSFontAttributeName:           [NSFont systemFontOfSize:11],
                               NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
                               NSParagraphStyleAttributeName:  psTight};

    NSMutableAttributedString *fsAS = [[NSMutableAttributedString alloc] init];
    [fsAS appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"Filesystem format based on:\n" attributes:greyAttr]];

    NSMutableDictionary *lnk1 = [greyAttr mutableCopy];
    lnk1[NSForegroundColorAttributeName] = [NSColor linkColor];
    lnk1[NSLinkAttributeName] = @"https://github.com/dagargo/emu3fs";
    [fsAS appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"dagargo/emu3fs" attributes:lnk1]];
    [fsAS appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"  ·  " attributes:greyAttr]];
    NSMutableDictionary *lnk2 = [greyAttr mutableCopy];
    lnk2[NSForegroundColorAttributeName] = [NSColor linkColor];
    lnk2[NSLinkAttributeName] = @"https://github.com/dagargo/emu3bm";
    [fsAS appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"dagargo/emu3bm" attributes:lnk2]];
    [fsAS appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"  (GPLv3)" attributes:greyAttr]];

    NSTextView *fsTV = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 30, 340, 50)];
    fsTV.drawsBackground = NO; fsTV.editable = NO; fsTV.selectable = YES;
    [fsTV.textStorage setAttributedString:fsAS];
    [v addSubview:fsTV];

    // ── OK button ─────────────────────────────────────────────────────────────
    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:NSApp action:@selector(stopModal)];
    ok.frame = NSMakeRect((380 - 68) / 2, 14, 68, 28);
    ok.keyEquivalent = @"\r";
    [v addSubview:ok];

    [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
}

@end
