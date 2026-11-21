#import "EMU3SamplerLink.h"
#import "MainWindowController.h"
#import "EMU3Types.h"
#import "EMU3BlockServer.h"

static NSString * const kDefaultsRW = @"SamplerLinkReadWrite";
static NSString * const kDefaultsImage = @"SamplerLinkImage";

@interface EMU3SamplerLinkController () <NSWindowDelegate>
@property (nonatomic, strong) EMU3BlockServer *server;
@property (nonatomic, strong) NSPopUpButton *imagePopup;
@property (nonatomic, strong) NSPopUpButton *accessPopup;
@property (nonatomic, strong) NSPopUpButton *idPopup;
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *hintLabel;
@property (nonatomic, strong) NSTextField *statsLabel;
@property (nonatomic, strong) NSView *dot;
@property (nonatomic, strong) NSTextView *logView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSArray<NSURL *> *imageChoices;
@end

@implementation EMU3SamplerLinkController

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 580, 520)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                  backing:NSBackingStoreBuffered defer:NO];
    win.title = @"Sampler Link";
    win.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:win])) {
        win.delegate = self;
        [self _buildUI];
        [win center];
    }
    return self;
}

- (BOOL)serving { return self.server.running; }
- (EMU3BlockServer *)activeServer { return self.server.running ? self.server : nil; }

- (void)noteImageEditedByApp {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 3.0) return;
    last = now;
    [self _appendLog:@"Edited on the Mac. Rescan the disk on the sampler before saving anything there."];
}
- (NSURL *)servedImageURL { return self.server.imageURL; }

#pragma mark - UI

static NSTextField *Label(NSString *s, NSFont *font, NSColor *color) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.font = font ?: [NSFont systemFontOfSize:NSFont.systemFontSize];
    if (color) t.textColor = color;
    return t;
}

- (void)_buildUI {
    NSView *content = self.window.contentView;

    NSTextField *title = Label(@"Live SCSI disk for the sampler", [NSFont boldSystemFontOfSize:15], nil);
    NSTextField *intro = Label(@"The BlueSCSI board asks this Mac for the disk blocks over USB. The sampler sees the image as a normal SCSI disk, and banks you copy here appear on it after a rescan.",
                               [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);
    intro.lineBreakMode = NSLineBreakByWordWrapping; intro.maximumNumberOfLines = 3;
    intro.preferredMaxLayoutWidth = 540;

    self.imagePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.imagePopup.target = self; self.imagePopup.action = @selector(_imagePicked:);
    self.accessPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.accessPopup addItemsWithTitles:@[@"Read-write (the sampler can save to it)", @"Read-only"]];
    [self.accessPopup selectItemAtIndex:[NSUserDefaults.standardUserDefaults objectForKey:kDefaultsRW] == nil ? 0 :
        ([NSUserDefaults.standardUserDefaults boolForKey:kDefaultsRW] ? 0 : 1)];
    self.accessPopup.target = self; self.accessPopup.action = @selector(_accessChanged:);

    self.startButton = [NSButton buttonWithTitle:@"Start Serving" target:self action:@selector(_startStop:)];
    self.startButton.bezelStyle = NSBezelStyleRegularSquare;
    self.startButton.keyEquivalent = @"\r";

    EMU3Tip(self.imagePopup, @"The image the sampler sees as its disk. It can only be changed while serving is stopped.");
    EMU3Tip(self.accessPopup, @"Read-write lets the sampler save to the disk. Read-only protects the image.");
    EMU3Tip(self.startButton, @"Start or stop giving the image to the sampler. The helper keeps serving when the app is closed.");
    NSStackView *row1 = [NSStackView stackViewWithViews:@[Label(@"Image:", nil, nil), self.imagePopup]];
    row1.spacing = 8; [self.imagePopup setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *row2 = [NSStackView stackViewWithViews:@[Label(@"Access:", nil, nil), self.accessPopup, self.startButton]];
    row2.spacing = 8;

    self.dot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 12, 12)];
    self.dot.wantsLayer = YES; self.dot.layer.cornerRadius = 6;
    self.dot.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dot.widthAnchor constraintEqualToConstant:12].active = YES;
    [self.dot.heightAnchor constraintEqualToConstant:12].active = YES;
    self.statusLabel = Label(@"Not serving", [NSFont boldSystemFontOfSize:13], nil);
    NSStackView *statusRow = [NSStackView stackViewWithViews:@[self.dot, self.statusLabel]];
    statusRow.spacing = 8;

    self.hintLabel = Label(@"", [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);
    self.hintLabel.lineBreakMode = NSLineBreakByWordWrapping; self.hintLabel.maximumNumberOfLines = 4;
    self.hintLabel.preferredMaxLayoutWidth = 540;
    self.statsLabel = Label(@"", [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular], NSColor.secondaryLabelColor);

    // The SCSI ID the board's disk answers at (the helper reads it from scsiid.txt; default 7).
    self.idPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (int i = 0; i < 8; i++) [self.idPopup addItemWithTitle:[NSString stringWithFormat:@"%d", i]];
    [self.idPopup selectItemAtIndex:[EMU3BlockServer boardSCSIID]];
    self.idPopup.target = self; self.idPopup.action = @selector(_idChanged:);
    EMU3Tip(self.idPopup, @"The SCSI ID the sampler addresses the board's disk at (default 7; the E64 sampler itself is ID 6). Rescan on the sampler after a change.");
    NSStackView *idRow = [NSStackView stackViewWithViews:@[Label(@"SCSI ID of the board's disk:", nil, nil), self.idPopup]];
    idRow.spacing = 8;
    // centered within the window width (the other rows stay left-aligned)
    NSView *idBox = [[NSView alloc] init];
    idBox.translatesAutoresizingMaskIntoConstraints = NO;
    idRow.translatesAutoresizingMaskIntoConstraints = NO;
    [idBox addSubview:idRow];
    [NSLayoutConstraint activateConstraints:@[
        [idRow.centerXAnchor constraintEqualToAnchor:idBox.centerXAnchor],
        [idRow.topAnchor constraintEqualToAnchor:idBox.topAnchor],
        [idRow.bottomAnchor constraintEqualToAnchor:idBox.bottomAnchor],
    ]];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 540, 150)];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSBezelBorder;
    self.logView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    self.logView.editable = NO;
    self.logView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.logView.autoresizingMask = NSViewWidthSizable;
    self.logView.textContainerInset = NSMakeSize(4, 4);
    EMU3Tip(self.logView, @"What the board and the sampler are doing. Right-click for Clear Log, Copy Log and Copy Status.");
    NSMenu *lm = [[NSMenu alloc] initWithTitle:@"Log"];
    NSMenuItem *mi = [lm addItemWithTitle:@"Clear Log" action:@selector(_clearLog:) keyEquivalent:@""]; mi.target = self;
    mi = [lm addItemWithTitle:@"Copy Log" action:@selector(_copyLog:) keyEquivalent:@""]; mi.target = self;
    mi = [lm addItemWithTitle:@"Copy Status" action:@selector(_copyStatus:) keyEquivalent:@""]; mi.target = self;
    self.logView.menu = lm;
    scroll.documentView = self.logView;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll.heightAnchor constraintEqualToConstant:150].active = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, intro, row1, row2, statusRow, self.hintLabel, self.statsLabel,
                                                           [NSBox new], idBox, scroll]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // separator
    NSBox *sep = (NSBox *)stack.arrangedSubviews[7]; sep.boxType = NSBoxSeparator;
    [sep.widthAnchor constraintEqualToConstant:540].active = YES;
    [content addSubview:stack];
    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(_closeWindow:)];
    close.bezelStyle = NSBezelStyleRegularSquare;
    close.keyEquivalent = @"\033";   // Esc
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:close];
    [NSLayoutConstraint activateConstraints:@[
        [close.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [close.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [close.topAnchor constraintGreaterThanOrEqualToAnchor:stack.bottomAnchor constant:8],
    ]];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [idBox.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
    [self _updateUI];
}

- (void)logLine:(NSString *)line { [self _appendLog:line]; }

- (void)_reloadImageChoices {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    if (self.mountedImageURLs) for (NSURL *u in self.mountedImageURLs()) if (![urls containsObject:u]) [urls addObject:u];
    NSURL *served = self.server.running ? self.server.imageURL : nil;
    if (served && ![urls containsObject:served]) [urls addObject:served];
    NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:kDefaultsImage];
    NSURL *selected = served;
    if (!selected && self.imagePopup.indexOfSelectedItem >= 0 && self.imagePopup.indexOfSelectedItem < (NSInteger)self.imageChoices.count)
        selected = self.imageChoices[self.imagePopup.indexOfSelectedItem];
    if (!selected && last) {
        NSURL *l = [NSURL fileURLWithPath:last];
        if ([NSFileManager.defaultManager fileExistsAtPath:last]) { selected = l; if (![urls containsObject:l]) [urls addObject:l]; }
    }
    self.imageChoices = urls;
    [self.imagePopup removeAllItems];
    for (NSURL *u in urls) {
        unsigned long long sz = [[NSFileManager.defaultManager attributesOfItemAtPath:u.path error:nil] fileSize];
        [self.imagePopup addItemWithTitle:[NSString stringWithFormat:@"%@  (%@)", u.lastPathComponent, EMU3FormatBytes(sz)]];
    }
    [self.imagePopup.menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *choose = [self.imagePopup.menu addItemWithTitle:@"Choose…" action:@selector(_chooseImage:) keyEquivalent:@""];
    choose.target = self;
    NSUInteger idx = selected ? [urls indexOfObject:selected] : NSNotFound;
    if (idx != NSNotFound) [self.imagePopup selectItemAtIndex:(NSInteger)idx];
    else if (urls.count) [self.imagePopup selectItemAtIndex:0];
}

- (void)showAndRefresh {
    [self _reloadImageChoices];
    [self _updateUI];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    if (!self.timer) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(_updateUI) userInfo:nil repeats:YES];
    }
}

- (void)windowWillClose:(NSNotification *)n {
    [self.timer invalidate]; self.timer = nil;   // the server keeps running with the window closed
}

#pragma mark - state display

- (void)_updateUI {
    BOOL running = self.server.running;
    self.startButton.title = running ? @"Stop Serving" : @"Start Serving";
    self.imagePopup.enabled = !running;
    self.accessPopup.enabled = !running;

    NSColor *col = NSColor.systemGrayColor;
    NSString *status = @"Not serving";
    NSString *hint = @"Pick an image and press Start Serving. In the sampler, rescan the SCSI bus afterwards.";
    if (running) {
        switch (self.server.state) {
            case EMU3LinkStateWaitingForBoard:
                col = NSColor.systemOrangeColor;
                status = @"Waiting for the board";
                hint = @"Plug the BlueSCSI in over USB with the sampler off, then switch the sampler on. The link starts by itself once the board shows up.";
                break;
            case EMU3LinkStateBoardConnected:
                col = NSColor.systemYellowColor;
                status = @"Board connected";
                hint = @"Waiting for the sampler to read the disk. Rescan the SCSI bus on the sampler.";
                break;
            case EMU3LinkStateActive: {
                col = NSColor.systemGreenColor;
                status = @"Serving to the sampler";
                NSTimeInterval age = self.server.lastActivity > 0 ? CFAbsoluteTimeGetCurrent() - self.server.lastActivity : 0;
                hint = age < 3 ? @"The sampler is accessing the disk right now."
                               : @"Connected. After you change banks on this Mac, rescan or re-open the disk on the sampler.";
                break;
            }
            default: break;
        }
    }
    self.dot.layer.backgroundColor = col.CGColor;
    self.statusLabel.stringValue = status;
    self.hintLabel.stringValue = hint;
    if (running) {
        self.statsLabel.stringValue = [NSString stringWithFormat:@"Reads %llu (%@)   Writes %llu (%@)   Last block %u   %@",
            self.server.readRequests, EMU3FormatBytes(self.server.bytesRead),
            self.server.writeRequests, EMU3FormatBytes(self.server.bytesWritten), self.server.lastLBA,
            self.server.portPath ? self.server.portPath.lastPathComponent : @""];
    } else {
        self.statsLabel.stringValue = @"";
    }
}

- (void)_clearLog:(id)sender { [self.logView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]]; }

- (void)_copyLog:(id)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.logView.string forType:NSPasteboardTypeString];
}

- (void)_copyStatus:(id)sender {
    NSString *t = [NSString stringWithFormat:@"%@\n%@", self.statusLabel.stringValue, self.statsLabel.stringValue];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:t forType:NSPasteboardTypeString];
}

- (void)_appendLog:(NSString *)line {
    static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss"; });
    NSString *s = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:NSDate.date], line];
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:@{
        NSFontAttributeName: self.logView.font, NSForegroundColorAttributeName: NSColor.labelColor}];
    [self.logView.textStorage appendAttributedString:as];
    [self.logView scrollToEndOfDocument:nil];
}

#pragma mark - actions

- (NSURL *)_selectedImage {
    NSInteger i = self.imagePopup.indexOfSelectedItem;
    return (i >= 0 && i < (NSInteger)self.imageChoices.count) ? self.imageChoices[(NSUInteger)i] : nil;
}

- (void)_imagePicked:(id)sender {
    NSURL *u = [self _selectedImage];
    if (u) [NSUserDefaults.standardUserDefaults setObject:u.path forKey:kDefaultsImage];
}

- (void)_accessChanged:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:(self.accessPopup.indexOfSelectedItem == 0) forKey:kDefaultsRW];
}

- (void)_chooseImage:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = @"Choose the disk image to serve to the sampler";
    p.canChooseFiles = YES; p.canChooseDirectories = NO;
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK && p.URL) {
            [NSUserDefaults.standardUserDefaults setObject:p.URL.path forKey:kDefaultsImage];
            if (self.openImage) self.openImage(p.URL);
            [self _reloadImageChoices];
            NSUInteger idx = [self.imageChoices indexOfObject:p.URL];
            if (idx != NSNotFound) [self.imagePopup selectItemAtIndex:(NSInteger)idx];
        } else {
            [self _reloadImageChoices];
        }
    }];
}

- (void)_idChanged:(id)sender {
    NSInteger sid = self.idPopup.indexOfSelectedItem;
    [EMU3BlockServer setBoardSCSIID:sid];
    [self _appendLog:[NSString stringWithFormat:@"The board's disk now answers at SCSI ID %ld. Rescan on the sampler%@.", (long)sid,
                      sid == 6 ? @" (6 is the E64's own ID, pick another)" : @""]];
}

- (void)_wireCallbacks:(EMU3BlockServer *)srv {
    __weak typeof(self) weak = self;
    srv.onChange = ^(EMU3BlockServer *s) { [weak _updateUI]; };
    srv.onLog = ^(NSString *line) { [weak _appendLog:line]; };
    srv.onImageChangedBySampler = ^(EMU3BlockServer *s) {
        [weak _appendLog:@"The sampler changed the image; reloading it here."];
        if (weak.imageChangedBySampler) weak.imageChangedBySampler(s.imageURL);
    };
}

// Called at launch: when the helper is already serving an image (it keeps going without the app), show that.
- (void)attachIfServed {
    if (self.server.running) return;
    EMU3BlockServer *srv = [EMU3BlockServer attachToServedImage];
    if (!srv) return;
    [self _wireCallbacks:srv];
    self.server = srv;
    if (self.servingChanged) self.servingChanged(srv);
    if (self.openImage) self.openImage(srv.imageURL);
    [self _updateUI];
}

- (void)_closeWindow:(id)sender {
    [self.window performClose:nil];   // serving continues in the background
}

- (void)_startStop:(id)sender {
    if (self.server.running) { [self stopServing]; return; }
    NSURL *url = [self _selectedImage];
    if (!url) { NSBeep(); return; }
    BOOL rw = self.accessPopup.indexOfSelectedItem == 0;
    EMU3BlockServer *srv = [[EMU3BlockServer alloc] initWithImageURL:url writable:rw];
    [self _wireCallbacks:srv];
    NSError *err = nil;
    if (![srv startWithError:&err]) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Cannot start serving";
        a.informativeText = err.localizedDescription ?: @"Unknown error";
        [a beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    if (srv.imageSize % 512 != 0)
        [self _appendLog:@"Warning: image size is not a multiple of 512 bytes."];
    self.server = srv;
    [NSUserDefaults.standardUserDefaults setObject:url.path forKey:kDefaultsImage];
    if (self.servingChanged) self.servingChanged(srv);
    // Make sure the served image is also open in the app, so edits made here show up on the sampler.
    BOOL open = NO;
    if (self.mountedImageURLs) for (NSURL *u in self.mountedImageURLs()) if ([u.path isEqualToString:url.path]) open = YES;
    if (!open && self.openImage) self.openImage(url);
    [self _updateUI];
}

- (void)stopServing {
    if (!self.server) return;
    [self.server stopServing];
    [self _appendLog:@"Stopped serving. The sampler loses this disk."];
    self.server = nil;
    if (self.servingChanged) self.servingChanged(nil);
    [self _updateUI];
}

@end
