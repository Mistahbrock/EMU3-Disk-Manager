#import "MainWindowController.h"
#import "EMU3Filesystem.h"
#import "EMU3Directory.h"
#import "EMU3File.h"
#import "EMU3SamplerLink.h"
#import "EMU3VolumeMount.h"
#import "EMU3BlockServer.h"
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// ── Tooltips ─────────────────────────────────────────────────────────────────
static NSString * const EMU3TooltipsKey = @"EMU3TooltipsEnabled";
static NSMapTable<id, NSString *> *gTips;   // object (weak) -> tip text

BOOL EMU3TooltipsEnabled(void) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:EMU3TooltipsKey];
    return v ? [v boolValue] : YES;
}

void EMU3Tip(id object, NSString *tip) {
    if (!object) return;
    if (!gTips) gTips = [NSMapTable weakToStrongObjectsMapTable];
    if (tip) [gTips setObject:tip forKey:object]; else [gTips removeObjectForKey:object];
    if ([object respondsToSelector:@selector(setToolTip:)])
        [object setToolTip:(EMU3TooltipsEnabled() ? tip : nil)];
}

void EMU3ApplyTooltipSetting(void) {
    BOOL on = EMU3TooltipsEnabled();
    for (id object in gTips.keyEnumerator.allObjects)
        if ([object respondsToSelector:@selector(setToolTip:)]) [object setToolTip:(on ? [gTips objectForKey:object] : nil)];
}
#import <objc/runtime.h>

static NSString * const EMU3MountedImageDragType = @"com.emu3diskmanager.mounted-image-copy";
// Plain drag of an image row = "the whole image content". The export to a temp folder used to run on the main thread
// while the drop was being accepted (beach ball); now the drop finds the exporter here and runs it in the background.
static NSString * const EMU3ImageContentDragType = @"com.emu3diskmanager.image-content";
static NSMutableDictionary<NSString *, NSURL *(^)(void)> *gImageDragExports;   // image path -> exporter
static NSMutableDictionary<NSString *, EMU3Filesystem *> *gImageDragSources;   // image path -> source filesystem
static BOOL gDropAlreadyConfirmed;   // set when the drop dialog was accepted, so the later space check does not ask again

// Exporters of all whole-image items on the drag pasteboard (several image rows can be dragged at once), or nil.
static NSArray<NSURL *(^)(void)> *EMU3ImageDragExporters(NSPasteboard *pb) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSPasteboardItem *it in pb.pasteboardItems) {
        NSString *path = [it stringForType:EMU3ImageContentDragType];
        NSURL *(^exp)(void) = path.length ? gImageDragExports[path] : nil;
        if (exp) [out addObject:exp];
    }
    return out.count ? out : nil;
}

// Firmware dialog: the standard centered box with a dropdown of the .uf2 files found nearby (identical copies shown once)
// and "Other…" for a file picker. Returns the chosen .uf2 path or nil.
@interface EMU3FWHelper : NSObject
@property (nonatomic, strong) NSPopUpButton *popup;
@property (nonatomic, strong) NSMutableArray<NSString *> *paths;
@property (nonatomic, strong) NSButton *okButton;
- (void)ok:(id)sender;
- (void)cancel:(id)sender;
- (void)choose:(id)sender;
@end
@implementation EMU3FWHelper
- (void)ok:(id)sender { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (void)reloadSelecting:(NSString *)sel {
    NSFileManager *fm = NSFileManager.defaultManager;
    [self.popup removeAllItems];
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"d MMM HH:mm";
    for (NSString *pth in self.paths) {
        NSDictionary *at = [fm attributesOfItemAtPath:pth error:nil];
        [self.popup addItemWithTitle:[NSString stringWithFormat:@"%@  ·  %.0f kB  ·  %@", pth.lastPathComponent,
                                      at.fileSize / 1024.0, [df stringFromDate:at.fileModificationDate] ?: @"?"]];
        self.popup.lastItem.toolTip = pth;
    }
    if (self.paths.count) [self.popup.menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *o = [self.popup.menu addItemWithTitle:@"Other…" action:@selector(choose:) keyEquivalent:@""];
    o.target = self;
    NSUInteger i = sel ? [self.paths indexOfObject:sel] : 0;
    if (self.paths.count) [self.popup selectItemAtIndex:(NSInteger)(i == NSNotFound ? 0 : i)];
    self.okButton.enabled = self.paths.count > 0;
}
- (NSString *)selectedPath {
    NSInteger i = self.popup.indexOfSelectedItem;
    return (i >= 0 && i < (NSInteger)self.paths.count) ? self.paths[(NSUInteger)i] : nil;
}
- (void)choose:(id)sender {
    NSString *prev = [self selectedPath];
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.message = @"Choose the BlueSCSI firmware file (.uf2) to flash onto the board.";
    UTType *uf2Type = [UTType typeWithFilenameExtension:@"uf2"];
    if (uf2Type) op.allowedContentTypes = @[uf2Type];
    NSString *chosen = prev;
    if ([op runModal] == NSModalResponseOK) {
        chosen = op.URL.path;
        if (![self.paths containsObject:chosen]) [self.paths insertObject:chosen atIndex:0];
    }
    [self reloadSelecting:chosen];
}
@end

static NSString *EMU3RunFirmwareDialog(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableArray<NSData *> *seen = [NSMutableArray array];
    for (NSString *dir in @[[NSHomeDirectory() stringByAppendingPathComponent:@"Developer/USB-SCSI/firmware/BlueSCSI-v2/build/Pico_2"],
                            [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"],
                            [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"],
                            @"/Library/Application Support/EMU3"])
        for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![n.pathExtension.lowercaseString isEqualToString:@"uf2"]) continue;
            NSString *pth = [dir stringByAppendingPathComponent:n];
            NSData *d = [NSData dataWithContentsOfFile:pth options:NSDataReadingMappedIfSafe error:nil];
            BOOL dup = NO; for (NSData *x in seen) if ([x isEqualToData:d]) { dup = YES; break; }
            if (dup) continue;
            [seen addObject:d ?: NSData.data]; [paths addObject:pth];
        }
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [[[fm attributesOfItemAtPath:b error:nil] fileModificationDate] compare:[[fm attributesOfItemAtPath:a error:nil] fileModificationDate]];
    }];
    const CGFloat W = 460;
    NSPanel *w = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, 100)
                                            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    EMU3FWHelper *h = [[EMU3FWHelper alloc] init];
    h.paths = paths;
    NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    NSTextField *t = [NSTextField wrappingLabelWithString:@"Update the BlueSCSI board firmware?"];
    t.font = [NSFont boldSystemFontOfSize:14]; t.alignment = NSTextAlignmentCenter;
    NSTextField *b = [NSTextField wrappingLabelWithString:@"The board restarts for about 15 seconds. The sampler loses its disk during that time, so do not load or save anything on the sampler. Afterwards the disk comes back by itself."];
    b.font = [NSFont systemFontOfSize:12]; b.alignment = NSTextAlignmentCenter;
    h.popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    h.popup.controlSize = NSControlSizeSmall; h.popup.font = [NSFont systemFontOfSize:11];
    NSButton *ok = [NSButton buttonWithTitle:@"Update" target:h action:@selector(ok:)];
    ok.bezelStyle = NSBezelStyleRegularSquare; ok.keyEquivalent = @"\r";
    h.okButton = ok;
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:h action:@selector(cancel:)];
    cancel.bezelStyle = NSBezelStyleRegularSquare; cancel.keyEquivalent = @"\e";
    [h reloadSelecting:nil];
    CGFloat tw = W - 60;
    NSSize ts = [t sizeThatFits:NSMakeSize(tw, CGFLOAT_MAX)];
    NSSize bs = [b sizeThatFits:NSMakeSize(tw, CGFLOAT_MAX)];
    CGFloat H = 20 + 64 + 12 + ts.height + 10 + bs.height + 16 + 26 + 18 + 32 + 16;
    [w setContentSize:NSMakeSize(W, H)];
    CGFloat y = H - 20 - 64;
    icon.frame = NSMakeRect((W - 64) / 2, y, 64, 64);
    y -= 12 + ts.height; t.frame = NSMakeRect(30, y, tw, ts.height);
    y -= 10 + bs.height; b.frame = NSMakeRect(30, y, tw, bs.height);
    y -= 16 + 26;
    h.popup.frame = NSMakeRect(30, y, tw, 26);
    ok.frame = NSMakeRect(W / 2 + 6, 16, 100, 32);
    cancel.frame = NSMakeRect(W / 2 - 106, 16, 100, 32);
    for (NSView *v in @[icon, t, b, h.popup, ok, cancel]) [w.contentView addSubview:v];
    w.defaultButtonCell = ok.cell;
    [w center];
    NSModalResponse r = [NSApp runModalForWindow:w];
    [w orderOut:nil];
    return r == NSModalResponseOK ? [h selectedPath] : nil;
}

static NSString *EMU3SizeString(unsigned long long bytes);
static BOOL EMU3RunCenteredConfirm(NSString *title, NSString *body, NSString *okTitle, NSString *cancelTitle);

// Table-based confirmation: rows = @[@[col1, col2], ...]; a row whose first cell starts with "\t" is shown bold (summary).
@interface EMU3RowsHelper : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *rows;
@end
@implementation EMU3RowsHelper
- (void)ok:(id)sender { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.rows.count; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)r {
    NSArray<NSString *> *row = self.rows[(NSUInteger)r];
    NSUInteger ci = [col.identifier isEqualToString:@"v"] ? 1 : 0;
    NSString *txt = row[ci];
    BOOL bold = [row[0] hasPrefix:@"\t"];
    if (ci == 0 && bold) txt = [txt substringFromIndex:1];
    NSTextField *f = [NSTextField labelWithString:txt];
    f.font = bold ? [NSFont boldSystemFontOfSize:10] : [NSFont systemFontOfSize:10];
    f.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return f;
}
@end

static BOOL EMU3RunTableConfirm(NSString *title, NSString *subtitle, NSArray<NSArray<NSString *> *> *rows,
                                NSString *okTitle, NSString *cancelTitle) {
    const CGFloat W = 620;
    NSPanel *w = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, 100)
                                            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    EMU3RowsHelper *h = [[EMU3RowsHelper alloc] init];
    h.rows = rows;
    NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    NSTextField *t = [NSTextField wrappingLabelWithString:title];
    t.font = [NSFont boldSystemFontOfSize:14]; t.alignment = NSTextAlignmentCenter;
    NSTextField *sub = [NSTextField wrappingLabelWithString:subtitle ?: @""];
    sub.font = [NSFont systemFontOfSize:11]; sub.textColor = NSColor.secondaryLabelColor; sub.alignment = NSTextAlignmentCenter;
    NSTableView *tv = [[NSTableView alloc] init];
    NSTableColumn *c0 = [[NSTableColumn alloc] initWithIdentifier:@"n"]; c0.title = @"Item"; c0.width = 350;
    NSTableColumn *c1 = [[NSTableColumn alloc] initWithIdentifier:@"v"]; c1.title = @"Size / info"; c1.width = 190;
    [tv addTableColumn:c0]; [tv addTableColumn:c1];
    tv.rowHeight = 15; tv.intercellSpacing = NSMakeSize(3, 2); tv.usesAlternatingRowBackgroundColors = YES;
    tv.dataSource = h; tv.delegate = h;
    NSScrollView *sv = [[NSScrollView alloc] init];
    sv.documentView = tv; sv.hasVerticalScroller = YES; sv.autohidesScrollers = YES; sv.borderType = NSBezelBorder;
    NSButton *ok = [NSButton buttonWithTitle:okTitle target:h action:@selector(ok:)];
    ok.bezelStyle = NSBezelStyleRegularSquare; ok.keyEquivalent = @"\r";
    NSButton *cancel = [NSButton buttonWithTitle:cancelTitle target:h action:@selector(cancel:)];
    cancel.bezelStyle = NSBezelStyleRegularSquare; cancel.keyEquivalent = @"\e";
    CGFloat tw = W - 60;
    NSSize ts = [t sizeThatFits:NSMakeSize(tw, CGFLOAT_MAX)];
    NSSize ss = [sub sizeThatFits:NSMakeSize(tw, CGFLOAT_MAX)];
    CGFloat tableH = MIN(MAX(rows.count * 17 + 30, 90), 640);
    CGFloat H = 16 + 48 + 8 + ts.height + 4 + ss.height + 10 + tableH + 16 + 32 + 16;
    [w setContentSize:NSMakeSize(W, H)];
    CGFloat y = H - 16 - 48;
    icon.frame = NSMakeRect((W - 48) / 2, y, 48, 48);
    y -= 8 + ts.height; t.frame = NSMakeRect(30, y, tw, ts.height);
    y -= 4 + ss.height; sub.frame = NSMakeRect(30, y, tw, ss.height);
    y -= 10 + tableH; sv.frame = NSMakeRect(30, y, tw, tableH);
    ok.frame = NSMakeRect(W / 2 + 6, 16, 100, 32);
    cancel.frame = NSMakeRect(W / 2 - 106, 16, 100, 32);
    for (NSView *v in @[icon, t, sub, sv, ok, cancel]) [w.contentView addSubview:v];
    w.defaultButtonCell = ok.cell;
    [w center];
    NSModalResponse r = [NSApp runModalForWindow:w];
    [w orderOut:nil];
    return r == NSModalResponseOK;
}

// Immediate dialog after dropping whole images onto a mount: what is copied, space, rough time.
static BOOL EMU3ConfirmImageDrop(NSPasteboard *pb, EMU3Filesystem *dest) {
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    unsigned long long total = 0;
    for (NSPasteboardItem *it in pb.pasteboardItems) {
        NSString *path = [it stringForType:EMU3ImageContentDragType];
        EMU3Filesystem *src = path.length ? gImageDragSources[path] : nil;
        if (!src) continue;
        unsigned long long used = (unsigned long long)src.usedBlocks * EMU3_BLOCK_SIZE;
        total += used;
        [rows addObject:@[path.lastPathComponent, [NSString stringWithFormat:@"%@ used", EMU3SizeString(used)]]];
    }
    if (!rows.count) return YES;
    unsigned long long freeB = (unsigned long long)dest.freeBlocks * EMU3_BLOCK_SIZE;
    // Files are exported to a temporary folder first and then written into the image: two passes, ~15 MB/s is a rough guess.
    double secs = total / (15.0 * 1024 * 1024);
    NSString *time = secs < 5 ? @"a few seconds" : secs < 90 ? [NSString stringWithFormat:@"about %.0f seconds", secs]
                                                          : [NSString stringWithFormat:@"about %.0f minutes", secs / 60];
    [rows addObject:@[@"\tTotal to copy", EMU3SizeString(total)]];
    [rows addObject:@[@"\tFree on the mount", [EMU3SizeString(freeB) stringByAppendingString:total > freeB ? @" (probably not enough)" : @""]]];
    [rows addObject:@[@"\tEstimated time", [time stringByAppendingString:@" (approximately)"]]];
    BOOL ok = EMU3RunTableConfirm([NSString stringWithFormat:@"These files will be copied onto \"%@\"",
                                       dest.imageURL.lastPathComponent.stringByDeletingPathExtension ?: @"this mount"],
                                  dest.imageURL.path ?: @"", rows, @"Continue", @"Cancel");
    gDropAlreadyConfirmed = ok;
    return ok;
}

// Runs the exporters one after the other in the background; then done(folders) on the main queue.
static void EMU3ExportDraggedImages(NSArray<NSURL *(^)(void)> *exporters, void (^done)(NSArray<NSURL *> *folders)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSURL *> *folders = [NSMutableArray array];
        for (NSURL *(^exp)(void) in exporters) { NSURL *f = exp(); if (f) [folders addObject:f]; }
        dispatch_async(dispatch_get_main_queue(), ^{ done(folders); });
    });
}

// ──────────────────────────────────────────────────────────────────────────────
// Custom NSOutlineView that detects double-clicks
// ──────────────────────────────────────────────────────────────────────────────

// Bank metadata can report 0 samples for banks whose sample chunks are not in the TOC
// the way the parser expects; fall back to the sample list used for export/expansion.
static NSUInteger EMU3ResolvedSampleCount(EMU3Filesystem *fs, EMU3File *file) {
    if (file.sampleCount > 0 || !fs || file.fileType != EMU3FileTypeBank) return file.sampleCount;
    NSUInteger n = [fs samplesFromBankFile:file error:nil].count;
    if (n > 0) file.sampleCount = n;
    return file.sampleCount;
}

// Puts a file URL on the pasteboard only when the drop target actually asks for it, so
// starting a drag of big folders is instant and the export happens once, at drop time.
static NSString *EMU3SizeString(unsigned long long bytes);

// Confirmation panel with the app icon centered on top (NSAlert always puts it at the left).
@interface EMU3ConfirmHelper : NSObject
- (void)ok:(id)sender;
- (void)cancel:(id)sender;
@end
@implementation EMU3ConfirmHelper
- (void)ok:(id)sender { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { [NSApp stopModalWithCode:NSModalResponseCancel]; }
@end

static BOOL EMU3RunCenteredConfirm(NSString *title, NSString *body, NSString *okTitle, NSString *cancelTitle) {
    const CGFloat W = 400;
    NSPanel *w = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, 100)
                                            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    EMU3ConfirmHelper *h = [[EMU3ConfirmHelper alloc] init];
    NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    NSTextField *t = [NSTextField wrappingLabelWithString:title];
    t.font = [NSFont boldSystemFontOfSize:14]; t.alignment = NSTextAlignmentCenter;
    NSTextField *b = [NSTextField wrappingLabelWithString:body];
    b.font = [NSFont systemFontOfSize:12]; b.alignment = NSTextAlignmentCenter;
    NSButton *ok = [NSButton buttonWithTitle:okTitle target:h action:@selector(ok:)];
    ok.bezelStyle = NSBezelStyleRegularSquare;
    ok.keyEquivalent = @"\r";
    NSButton *cancel = [NSButton buttonWithTitle:cancelTitle target:h action:@selector(cancel:)];
    cancel.bezelStyle = NSBezelStyleRegularSquare;
    cancel.keyEquivalent = @"\e";
    CGFloat tw = W - 60;
    NSSize ts = [t sizeThatFits:NSMakeSize(tw, CGFLOAT_MAX)];
    NSSize bs = [b sizeThatFits:NSMakeSize(tw, CGFLOAT_MAX)];
    CGFloat H = 20 + 64 + 12 + ts.height + 10 + bs.height + 18 + 32 + 16;
    [w setContentSize:NSMakeSize(W, H)];
    CGFloat y = H - 20 - 64;
    icon.frame = NSMakeRect((W - 64) / 2, y, 64, 64);
    y -= 12 + ts.height; t.frame = NSMakeRect(30, y, tw, ts.height);
    y -= 10 + bs.height; b.frame = NSMakeRect(30, y, tw, bs.height);
    ok.frame = NSMakeRect(W / 2 + 6, 16, 100, 32);
    cancel.frame = NSMakeRect(W / 2 - 106, 16, 100, 32);
    for (NSView *v in @[icon, t, b, ok, cancel]) [w.contentView addSubview:v];
    w.defaultButtonCell = ok.cell;
    [w center];
    NSModalResponse r = [NSApp runModalForWindow:w];
    [w orderOut:nil];
    return r == NSModalResponseOK;
}

static NSDictionary *EMU3DiskInfo(NSString *target);

// YES when `url` lives on an SD card that is mounted through the BlueSCSI board's own USB port.
// That link is USB full speed (about 1 MB/s), far too slow for copying images or banks.
static BOOL EMU3IsBoardUSBVolume(NSURL *url) {
    if (!url) return NO;
    NSURL *vol = nil;
    [url getResourceValue:&vol forKey:NSURLVolumeURLKey error:nil];
    if (!vol) vol = url;
    static NSMutableDictionary<NSString *, NSArray *> *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSArray *hit = cache[vol.path];
        if (hit && CFAbsoluteTimeGetCurrent() - [hit[1] doubleValue] < 10.0) return [hit[0] boolValue];
    }
    BOOL isBoard = NO;
    NSDictionary *vi = EMU3DiskInfo(vol.path);
    NSString *whole = vi[@"ParentWholeDisk"];
    NSDictionary *di = whole ? EMU3DiskInfo([@"/dev/" stringByAppendingString:whole]) : nil;
    if (di && ![di[@"Internal"] boolValue]) {
        for (id v in di.allValues)
            if ([v isKindOfClass:NSString.class] && [(NSString *)v rangeOfString:@"bluescsi" options:NSCaseInsensitiveSearch].location != NSNotFound) { isBoard = YES; break; }
    }
    @synchronized (cache) { cache[vol.path] = @[@(isBoard), @(CFAbsoluteTimeGetCurrent())]; }
    return isBoard;
}

static void EMU3ShowBoardUSBRefusal(NSString *what) {
    NSAlert *a = [[NSAlert alloc] init];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = @"The SD card is connected through the BlueSCSI's USB port";
    a.informativeText = [NSString stringWithFormat:
        @"%@ is not possible over that link: it runs at about 1 MB/s, so a large image would take hours and may stall.\n\n"
        @"Eject the card, take it out of the BlueSCSI and use a card reader on the Mac. For live editing while the sampler runs, use Tools ▸ Sampler Link instead.", what];
    [a addButtonWithTitle:@"OK"];
    [a runModal];
}

// Disclosure triangle behaviour for the Get Info sections (like the Finder's Get Info window).
@interface EMU3InfoToggler : NSObject
@property (nonatomic, weak) NSView *content;
@property (nonatomic, weak) NSStackView *stack;
@property (nonatomic, weak) NSWindow *window;
- (void)toggle:(NSButton *)sender;
@end
@implementation EMU3InfoToggler
- (void)toggle:(NSButton *)sender {
    self.content.hidden = (sender.state != NSControlStateValueOn);
    [self.stack layoutSubtreeIfNeeded];
    NSSize fit = self.stack.fittingSize;
    NSRect fr = self.window.frame;
    NSRect nf = [self.window frameRectForContentRect:NSMakeRect(0, 0, fit.width, fit.height)];
    nf.origin.x = fr.origin.x; nf.origin.y = NSMaxY(fr) - nf.size.height;
    [self.window setFrame:nf display:YES animate:YES];
}
@end

// Data source for the Items tab of the Get Info panel.
@interface EMU3InfoRows : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *rows;   // name, folder, type, size, disk
@end
@implementation EMU3InfoRows
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.rows.count; }
- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSDictionary *r = self.rows[(NSUInteger)row];
    id v = r[col.identifier];
    if ([col.identifier isEqualToString:@"size"] || [col.identifier isEqualToString:@"disk"])
        return EMU3SizeString([v unsignedLongLongValue]);
    return v ?: @"";
}
- (void)tableView:(NSTableView *)tv sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old {
    self.rows = [self.rows sortedArrayUsingDescriptors:tv.sortDescriptors];
    [tv reloadData];
}
@end

@interface EMU3LazyFileURLProvider : NSObject <NSPasteboardItemDataProvider>
@property (nonatomic, copy) NSURL *(^exporter)(void);
@end
@implementation EMU3LazyFileURLProvider
- (void)pasteboard:(NSPasteboard *)pasteboard item:(NSPasteboardItem *)item provideDataForType:(NSPasteboardType)type {
    NSURL *url = self.exporter ? self.exporter() : nil;
    NSLog(@"[DragProvider] type=%@ -> %@", type, url);
    if (url) [item setString:url.absoluteString forType:NSPasteboardTypeFileURL];
}
@end

// Short, readable E-mu folder name (max 15 chars) for a long image/folder name, instead of
// cutting it off: "Producer_Series_Vol.3_Hollywood_Sound_Effects" -> "V3 Hollywood",
// "Producer_Series_Vol.6_Analogia_Project(CD2)" -> "V6 Analogia CD2".
static NSString *EMU3ShortFolderName(NSString *name) {
    const NSUInteger kMax = 15;
    if (name.length <= kMax) return name;

    NSString *base = name;
    NSString *tag = @"";
    NSRange open = [base rangeOfString:@"(" options:NSBackwardsSearch];
    if (open.location != NSNotFound && [base hasSuffix:@")"]) {
        tag = [[base substringWithRange:NSMakeRange(open.location + 1, base.length - open.location - 2)]
               stringByReplacingOccurrencesOfString:@" " withString:@""];
        base = [base substringToIndex:open.location];
    }
    base = [base stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    for (NSString *noise in @[@"Producer Series ", @"EMU Formula 4000 Series ", @"EMU ", @"Production Set",
                              @"Production", @" Collection", @" Project"])
        base = [base stringByReplacingOccurrencesOfString:noise withString:@""];
    base = [base stringByReplacingOccurrencesOfString:@"Vol." withString:@"V"];
    base = [base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (base.length == 0) base = name;

    NSUInteger room = tag.length ? kMax - tag.length - 1 : kMax;
    NSMutableString *out = [NSMutableString string];
    for (NSString *w in [base componentsSeparatedByString:@" "]) {
        if (w.length == 0) continue;
        NSString *cand = out.length ? [NSString stringWithFormat:@"%@ %@", out, w] : w;
        if (cand.length > room) break;
        out = [cand mutableCopy];
    }
    if (out.length == 0) out = [[base substringToIndex:MIN(base.length, room)] mutableCopy];
    return tag.length ? [NSString stringWithFormat:@"%@ %@", out, tag] : [out copy];
}

// Makes the name unique among the sub-folders of dir (adds 2, 3, ... within 15 chars).
static NSString *EMU3UniqueFolderName(NSString *name, EMU3Directory *dir) {
    NSMutableSet *taken = [NSMutableSet set];
    for (EMU3Directory *d in dir.subdirectories) if (d.name) [taken addObject:d.name.lowercaseString];
    if (![taken containsObject:name.lowercaseString]) return name;
    for (NSUInteger n = 2; n < 1000; n++) {
        NSString *suffix = [NSString stringWithFormat:@" %lu", (unsigned long)n];
        NSString *stem = name.length + suffix.length > 15 ? [name substringToIndex:15 - suffix.length] : name;
        NSString *cand = [stem stringByAppendingString:suffix];
        if (![taken containsObject:cand.lowercaseString]) return cand;
    }
    return name;
}

@interface ClickableOutlineView : NSOutlineView
@property (nonatomic, copy) void (^onDoubleClick)(NSInteger row);
@property (nonatomic, copy) void (^onDeleteKey)(void);
@end

@implementation ClickableOutlineView
- (void)keyDown:(NSEvent *)event {
    NSString *c = event.charactersIgnoringModifiers;
    if (self.onDeleteKey && c.length == 1 &&
        ([c characterAtIndex:0] == NSDeleteCharacter || [c characterAtIndex:0] == NSDeleteFunctionKey)) {
        self.onDeleteKey();
        return;
    }
    [super keyDown:event];
}
- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) {
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        NSInteger row = [self rowAtPoint:point];
        if (row >= 0 && self.onDoubleClick) {
            self.onDoubleClick(row);
            return;
        }
    }
    [super mouseDown:event];
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:point];
    if (row >= 0 && ![self.selectedRowIndexes containsIndex:(NSUInteger)row]) {
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    }
    [super rightMouseDown:event];
}
@end

// ──────────────────────────────────────────────────────────────────────────────
// MountedImagesController - Manages the list of mounted disk images
// The sampler strip: a drop target for whole images and Finder files (they go into the served image).
@interface EMU3SamplerStripView : NSView
@property (nonatomic, copy) BOOL (^dropHandler)(NSPasteboard *pb);
@property (nonatomic, assign) BOOL selected;
@end
@implementation EMU3SamplerStripView
- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, EMU3ImageContentDragType]];
    self.wantsLayer = YES;
    return self;
}
- (void)setSelected:(BOOL)sel {
    _selected = sel;
    self.layer.backgroundColor = sel ? [NSColor.selectedContentBackgroundColor colorWithAlphaComponent:0.25].CGColor : NSColor.clearColor.CGColor;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return self.dropHandler ? NSDragOperationCopy : NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info { return self.dropHandler ? self.dropHandler(info.draggingPasteboard) : NO; }
@end

// ──────────────────────────────────────────────────────────────────────────────

@interface MountedImagesController : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
// Called when the user selects an image (dir == nil) or a folder inside an image.
@property (nonatomic, copy)   void (^selectionChanged)(EMU3Filesystem *filesystem, EMU3Directory *directory);
// Called when items are dropped on an image or on a folder in the tree.
// directory == nil means "the image itself" (root / default folder).
@property (nonatomic, copy)   void (^itemsDropped)(EMU3Filesystem *filesystem, EMU3Directory *directory,
                                                   NSArray<NSURL *> *urls, BOOL isInternal, BOOL isMove);
@property (nonatomic, copy)   void (^imageCopyDropped)(NSURL *imageURL);
@property (nonatomic, copy)   void (^statusUpdate)(NSString *msg);
@property (nonatomic, assign) NSInteger sortMode;   // 0 = A-Z, 1 = Z-A, 2 = mount / disk order
@property (nonatomic, copy)   BOOL (^imageFolderExporter)(EMU3Filesystem *fs, NSURL *folderURL);
@property (nonatomic, strong) NSMutableArray *imageFolderProviders;
@property (nonatomic, weak)   NSOutlineView *outlineView;
// The file list on the right. Drags that start there are "internal" and may move files.
@property (nonatomic, weak)   NSView *internalDragSource;
@property (nonatomic, strong) NSMutableArray<EMU3Filesystem *> *filesystems;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *dragCopyCountersByPath;

// The image served to the sampler is shown in the strip above the list, not in the list.
@property (nonatomic, weak) EMU3Filesystem *hiddenFilesystem;

- (void)addMountedFilesystem:(EMU3Filesystem *)fs;
- (void)removeMountedFilesystem:(EMU3Filesystem *)fs;
- (void)reloadData;
- (void)selectFilesystem:(EMU3Filesystem *)fs directory:(EMU3Directory *)dir;
- (EMU3Filesystem *)filesystemForItem:(id)item;
@end

@implementation MountedImagesController {
    BOOL _suppressSelection;
    BOOL _reloadPending;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _filesystems = [NSMutableArray array];
        _dragCopyCountersByPath = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)addMountedFilesystem:(EMU3Filesystem *)fs {
    if (fs) {
        [self.filesystems addObject:fs];
        [self.outlineView reloadData];
    }
}

- (void)removeMountedFilesystem:(EMU3Filesystem *)fs {
    [self.filesystems removeObject:fs];
    [self.outlineView reloadData];
}

// Reloads the tree (folders may have been added, renamed or removed) while keeping
// the expanded folders and the selection. Coalesced so it is cheap to call often.
- (void)reloadData {
    if (_reloadPending) return;
    _reloadPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_reloadPending = NO;
        [self _reloadPreservingState];
    });
}

- (void)expandAll {
    [self.outlineView expandItem:nil expandChildren:YES];
}

- (void)collapseAll {
    NSOutlineView *ov = self.outlineView;
    _suppressSelection = YES;
    [ov collapseItem:nil collapseChildren:YES];
    // Keep the images themselves visible one level down so the tree is not empty.
    for (EMU3Filesystem *fs in self.filesystems) [ov collapseItem:fs];
    _suppressSelection = NO;
}

- (void)_reloadPreservingState {
    NSOutlineView *ov = self.outlineView;
    if (!ov) return;

    NSMutableArray *expanded = [NSMutableArray array];
    for (NSInteger row = 0; row < ov.numberOfRows; row++) {
        id item = [ov itemAtRow:row];
        if ([ov isItemExpanded:item]) [expanded addObject:item];
    }
    NSMutableArray *selectedItems = [NSMutableArray array];
    [ov.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        id it = [ov itemAtRow:(NSInteger)idx];
        if (it) [selectedItems addObject:it];
    }];

    _suppressSelection = YES;
    [ov reloadData];
    for (id item in expanded) {
        if ([self _itemStillExists:item]) [ov expandItem:item];
    }
    NSMutableIndexSet *restore = [NSMutableIndexSet indexSet];
    for (id selected in selectedItems) {
        if (![self _itemStillExists:selected]) continue;
        NSInteger row = [ov rowForItem:selected];
        if (row >= 0) [restore addIndex:(NSUInteger)row];
    }
    if (restore.count) [ov selectRowIndexes:restore byExtendingSelection:NO];
    _suppressSelection = NO;
}

- (BOOL)_itemStillExists:(id)item {
    if ([item isKindOfClass:[EMU3Filesystem class]]) return [self.filesystems containsObject:item];
    if ([item isKindOfClass:[EMU3Directory class]]) {
        EMU3Directory *dir = item;
        EMU3Directory *parent = dir.parent;
        // Walk up to the root, checking that each step is still a child of its parent.
        while (parent) {
            if (![parent.subdirectories containsObject:dir]) return NO;
            dir = parent;
            parent = dir.parent;
        }
        for (EMU3Filesystem *fs in self.filesystems) {
            if (fs.rootDirectory == dir) return YES;
        }
    }
    return NO;
}

- (EMU3Filesystem *)filesystemForItem:(id)item {
    if ([item isKindOfClass:[EMU3Filesystem class]]) return item;
    if ([item isKindOfClass:[EMU3Directory class]]) {
        EMU3Directory *dir = item;
        while (dir.parent) dir = dir.parent;
        for (EMU3Filesystem *fs in self.filesystems) {
            if (fs.rootDirectory == dir) return fs;
        }
    }
    return nil;
}

// Select an image or a folder in the tree without triggering the selection callback.
- (void)selectFilesystem:(EMU3Filesystem *)fs directory:(EMU3Directory *)dir {
    NSOutlineView *ov = self.outlineView;
    if (!ov || !fs || ![self.filesystems containsObject:fs]) return;
    if (fs == self.hiddenFilesystem) {   // shown in the strip: just clear the list selection
        _suppressSelection = YES; [ov deselectAll:nil]; _suppressSelection = NO;
        return;
    }

    BOOL isRoot = (!dir || dir == fs.rootDirectory);
    NSMutableArray<EMU3Directory *> *path = [NSMutableArray array];
    if (!isRoot) {
        EMU3Directory *d = dir;
        while (d && d != fs.rootDirectory) { [path insertObject:d atIndex:0]; d = d.parent; }
        if (d != fs.rootDirectory) { path = [NSMutableArray array]; isRoot = YES; }
    }

    _suppressSelection = YES;
    // Start collapsed: only open the branch that is needed to show a selected folder.
    if (!isRoot) {
        [ov expandItem:fs];
        for (NSUInteger i = 0; i + 1 < path.count; i++) [ov expandItem:path[i]];
    }
    id target = isRoot ? (id)fs : (id)path.lastObject;
    NSInteger row = [ov rowForItem:target];
    if (row >= 0) {
        [ov selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        [ov scrollRowToVisible:row];
    }
    _suppressSelection = NO;
}

// ── Data source ─────────────────────────────────────────────────────────────

// Tree order follows sortMode (default A-Z; images by file name, folders by name).
- (NSArray<EMU3Filesystem *> *)_sortedFilesystems {
    NSMutableArray<EMU3Filesystem *> *visible = [self.filesystems mutableCopy];
    if (self.hiddenFilesystem) [visible removeObject:self.hiddenFilesystem];
    if (self.sortMode == 2) return visible;
    BOOL desc = self.sortMode == 1;
    return [visible sortedArrayUsingComparator:^NSComparisonResult(EMU3Filesystem *a, EMU3Filesystem *b) {
        NSComparisonResult r = [a.imageURL.lastPathComponent localizedStandardCompare:b.imageURL.lastPathComponent ?: @""];
        return desc ? -r : r;
    }];
}

- (NSArray<EMU3Directory *> *)_sortedSubdirectoriesOf:(EMU3Directory *)dir {
    if (self.sortMode == 2) return [dir.subdirectories copy];
    BOOL desc = self.sortMode == 1;
    return [dir.subdirectories sortedArrayUsingComparator:^NSComparisonResult(EMU3Directory *a, EMU3Directory *b) {
        NSComparisonResult r = [a.name ?: @"" localizedStandardCompare:b.name ?: @""];
        return desc ? -r : r;
    }];
}

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return (NSInteger)[self _sortedFilesystems].count;
    if ([item isKindOfClass:[EMU3Filesystem class]])
        return (NSInteger)((EMU3Filesystem *)item).rootDirectory.subdirectories.count;
    if ([item isKindOfClass:[EMU3Directory class]])
        return (NSInteger)((EMU3Directory *)item).subdirectories.count;
    return 0;
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    return [self outlineView:ov numberOfChildrenOfItem:item] > 0;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!item) return [self _sortedFilesystems][(NSUInteger)index];
    if ([item isKindOfClass:[EMU3Filesystem class]])
        return [self _sortedSubdirectoriesOf:((EMU3Filesystem *)item).rootDirectory][(NSUInteger)index];
    return [self _sortedSubdirectoriesOf:(EMU3Directory *)item][(NSUInteger)index];
}

- (id)outlineView:(NSOutlineView *)ov objectValueForTableColumn:(NSTableColumn *)col byItem:(id)item {
    return nil; // view-based
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    BOOL isImage = [item isKindOfClass:[EMU3Filesystem class]];
    NSString *ident = isImage ? @"ImageCell" : @"FolderCell";
    NSTableCellView *cell = [ov makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = ident;
        NSImageView *img = [[NSImageView alloc] initWithFrame:NSMakeRect(2, 1, 16, 16)];
        NSString *symbol = isImage ? @"internaldrive" : @"folder";
        NSImage *icon = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
        img.image = icon ?: [NSImage imageNamed:NSImageNameFolder];
        img.contentTintColor = NSColor.secondaryLabelColor;
        [cell addSubview:img];
        cell.imageView = img;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.frame = NSMakeRect(22, 1, col.width - 26, 16);
        tf.autoresizingMask = NSViewWidthSizable;
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        tf.font = [NSFont systemFontOfSize:11];
        [cell addSubview:tf];
        cell.textField = tf;
    }
    if (isImage) {
        EMU3Filesystem *fs = item;
        NSString *filename = fs.imageURL.lastPathComponent ?: @"(Unnamed)";
        cell.textField.stringValue = [filename stringByDeletingPathExtension];
    } else {
        cell.textField.stringValue = ((EMU3Directory *)item).name ?: @"";
    }
    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    if (_suppressSelection) return;
    NSOutlineView *ov = notification.object;
    // Shift/Cmd-click builds a multi-selection (e.g. several images to unmount);
    // only a single selected row navigates the right pane.
    if (ov.selectedRowIndexes.count != 1) return;
    NSInteger row = ov.selectedRow;
    if (row < 0) return;
    id item = [ov itemAtRow:row];
    EMU3Filesystem *fs = [self filesystemForItem:item];
    if (!fs || !self.selectionChanged) return;
    EMU3Directory *dir = [item isKindOfClass:[EMU3Directory class]] ? item : nil;
    self.selectionChanged(fs, dir);
}

// ── Drag source: Option-drag an image row to copy the image file ────────────

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov pasteboardWriterForItem:(id)item {
    if (![item isKindOfClass:[EMU3Filesystem class]]) return nil;

    NSEventModifierFlags flags = NSApp.currentEvent.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & NSEventModifierFlagOption) == 0) {
        // Plain drag of an image row: the whole image content as a folder (named after the image).
        EMU3Filesystem *srcFS = item;
        if (!self.imageFolderExporter) return nil;
        __weak MountedImagesController *wSelf = self;
        EMU3LazyFileURLProvider *provider = [[EMU3LazyFileURLProvider alloc] init];
        provider.exporter = ^NSURL *{
            NSString *name = srcFS.imageURL.lastPathComponent.stringByDeletingPathExtension ?: @"Image";
            NSURL *dir = [[[NSURL fileURLWithPath:NSTemporaryDirectory()]
                            URLByAppendingPathComponent:@"EMU3ImageAsFolder"]
                           URLByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            NSURL *folder = [dir URLByAppendingPathComponent:name];
            return wSelf.imageFolderExporter(srcFS, folder) ? folder : nil;
        };
        if (!self.imageFolderProviders) self.imageFolderProviders = [NSMutableArray array];
        [self.imageFolderProviders addObject:provider];
        NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
        [pbItem setDataProvider:provider forTypes:@[NSPasteboardTypeFileURL]];
        if (!gImageDragExports) gImageDragExports = [NSMutableDictionary dictionary];
        gImageDragExports[srcFS.imageURL.path] = provider.exporter;
        if (!gImageDragSources) gImageDragSources = [NSMutableDictionary dictionary];
        gImageDragSources[srcFS.imageURL.path] = srcFS;
        [pbItem setString:srcFS.imageURL.path forType:EMU3ImageContentDragType];
        return pbItem;
    }

    EMU3Filesystem *fs = item;
    if (!fs.imageURL.isFileURL) return nil;

    NSError *error = nil;
    if (![fs synchronizeToDisk:&error]) {
        NSLog(@"Could not flush image before drag copy: %@", error);
    }

    NSURL *sourceURL = fs.imageURL;
    NSString *sourceName = sourceURL.lastPathComponent ?: @"DiskImage.hda";
    NSString *baseName = sourceName.stringByDeletingPathExtension;
    NSString *extension = sourceName.pathExtension;
    NSString *sourcePath = sourceURL.path.stringByStandardizingPath ?: sourceName;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *copyDir = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:@"EMU3ImageDragCopies"
                         isDirectory:YES];
    if (![fm createDirectoryAtURL:copyDir withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"Could not create image drag copy folder: %@", error);
        return sourceURL;
    }

    NSUInteger counter = self.dragCopyCountersByPath[sourcePath].unsignedIntegerValue + 1;
    NSURL *copyURL = nil;
    do {
        NSString *copyName = extension.length > 0
            ? [NSString stringWithFormat:@"%@_%lu.%@", baseName, (unsigned long)counter, extension]
            : [NSString stringWithFormat:@"%@_%lu", sourceName, (unsigned long)counter];
        copyURL = [copyDir URLByAppendingPathComponent:copyName];
        counter++;
    } while ([fm fileExistsAtPath:copyURL.path]);
    self.dragCopyCountersByPath[sourcePath] = @(counter - 1);

    if (![fm copyItemAtURL:sourceURL toURL:copyURL error:&error]) {
        NSLog(@"Could not create numbered image drag copy: %@", error);
        return sourceURL;
    }

    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setString:copyURL.absoluteString forType:NSPasteboardTypeFileURL];
    [pbItem setString:copyURL.absoluteString forType:EMU3MountedImageDragType];
    return pbItem;
}

- (NSDragOperation)outlineView:(NSOutlineView *)ov
               draggingSession:(NSDraggingSession *)session
sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy;
}

// ── Drop target: images and folders ─────────────────────────────────────────

- (NSDragOperation)outlineView:(NSOutlineView *)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {
    NSPasteboard *pb = info.draggingPasteboard;

    // Option-dragged image copy dropped back on the tree: mounts the copy.
    if (info.draggingSource == ov && [pb stringForType:EMU3MountedImageDragType].length > 0) {
        [ov setDropItem:nil dropChildIndex:NSOutlineViewDropOnItemIndex];
        return NSDragOperationCopy;
    }

    EMU3Filesystem *fs = [self filesystemForItem:item];
    if (!item || !fs || fs.isReadOnly) return NSDragOperationNone;

    NSDictionary *opts = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    if (![pb canReadObjectForClasses:@[NSURL.class] options:opts]) return NSDragOperationNone;

    // Always drop ON an image or folder, never between rows.
    [ov setDropItem:item dropChildIndex:NSOutlineViewDropOnItemIndex];

    BOOL isInternal = (self.internalDragSource && info.draggingSource == self.internalDragSource);
    BOOL optionDown = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    if (isInternal && !optionDown && (info.draggingSourceOperationMask & NSDragOperationMove))
        return NSDragOperationMove;
    return NSDragOperationCopy;
}

- (BOOL)outlineView:(NSOutlineView *)ov
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)index {
    NSPasteboard *pb = info.draggingPasteboard;

    NSString *copiedImageURLString = [pb stringForType:EMU3MountedImageDragType];
    if (info.draggingSource == ov && copiedImageURLString.length > 0 && self.imageCopyDropped) {
        NSURL *copiedImageURL = [NSURL URLWithString:copiedImageURLString];
        if (!copiedImageURL.isFileURL) return NO;
        self.imageCopyDropped(copiedImageURL);
        return YES;
    }

    EMU3Filesystem *fs = [self filesystemForItem:item];
    if (!fs || fs.isReadOnly || !self.itemsDropped) return NO;

    // A whole image dragged from another row: export it in the background, then import (never on the main thread).
    NSArray<NSURL *(^)(void)> *imgExports = EMU3ImageDragExporters(pb);
    if (imgExports) {
        if (!EMU3ConfirmImageDrop(pb, fs)) return YES;
        EMU3Directory *dstDir = [item isKindOfClass:[EMU3Directory class]] ? item : nil;
        if (self.statusUpdate) self.statusUpdate([NSString stringWithFormat:@"Reading %lu image%@…", (unsigned long)imgExports.count, imgExports.count == 1 ? @"" : @"s"]);
        EMU3ExportDraggedImages(imgExports, ^(NSArray<NSURL *> *folders) {
            if (!folders.count) { if (self.statusUpdate) self.statusUpdate(@"Could not read the image."); return; }
            self.itemsDropped(fs, dstDir, folders, NO, NO);
        });
        return YES;
    }

    NSDictionary *opts = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[NSURL.class] options:opts];
    NSLog(@"[TreeDrop] item=%@ urls=%@", item, urls);
    if (urls.count == 0) return NO;

    BOOL isInternal = (self.internalDragSource && info.draggingSource == self.internalDragSource);
    BOOL optionDown = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    BOOL isMove = isInternal && !optionDown && (info.draggingSourceOperationMask & NSDragOperationMove);
    EMU3Directory *dir = [item isKindOfClass:[EMU3Directory class]] ? item : nil;
    self.itemsDropped(fs, dir, urls, isInternal, isMove);
    return YES;
}

@end

// ──────────────────────────────────────────────────────────────────────────────
// Sidebar (directory tree)
// ──────────────────────────────────────────────────────────────────────────────

@interface SidebarController : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property (nonatomic, strong) EMU3Directory  *root;
@property (nonatomic, copy)   void (^selectionChanged)(EMU3Directory *dir);
@property (nonatomic, weak)   NSOutlineView  *outlineView;
// Drag destination support
@property (nonatomic, weak)   NSTableView    *sourceTableView; // our file table — detects internal drags
@property (nonatomic, copy)   NSDragOperation (^validateDropBlock)(EMU3Directory *target, BOOL isInternal);
@property (nonatomic, copy)   void (^dropReceived)(EMU3Directory *target, NSArray<NSURL *> *urls, BOOL isInternal);
@end

@implementation SidebarController

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    EMU3Directory *dir = item ?: self.root;
    return (NSInteger)dir.subdirectories.count;
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    EMU3Directory *dir = item ?: self.root;
    return dir.subdirectories.count > 0;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    EMU3Directory *dir = item ?: self.root;
    return dir.subdirectories[index];
}
- (id)outlineView:(NSOutlineView *)ov objectValueForTableColumn:(NSTableColumn *)col byItem:(id)item {
    return nil; // using view-based
}
- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    EMU3Directory *dir = item;
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"DirCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"DirCell";
        NSImageView *img = [[NSImageView alloc] initWithFrame:NSMakeRect(4,2,16,16)];
        img.image = [NSImage imageNamed:NSImageNameFolder];
        img.autoresizingMask = NSViewNotSizable;
        cell.imageView = img;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.frame = NSMakeRect(24,2,200,16);
        tf.autoresizingMask = NSViewWidthSizable;
        tf.font = [NSFont systemFontOfSize:12];
        [cell addSubview:img];
        [cell addSubview:tf];
        cell.textField = tf;
    }
    cell.textField.stringValue = dir.name ?: @"";
    NSUInteger count = dir.totalFileCount;
    cell.textField.stringValue = count > 0
        ? [NSString stringWithFormat:@"%@ (%lu)", dir.name, (unsigned long)count]
        : dir.name;
    return cell;
}
- (void)outlineViewSelectionDidChange:(NSNotification *)n {
    NSOutlineView *ov = n.object;
    EMU3Directory *sel = [ov itemAtRow:ov.selectedRow];
    if (!sel) sel = self.root;
    if (self.selectionChanged) self.selectionChanged(sel);
}

// ── Drag destination: accept file drops onto a directory row ─────────────────
- (NSDragOperation)outlineView:(NSOutlineView *)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)idx {
    if (!self.root) return NSDragOperationNone;
    NSPasteboard *pb = info.draggingPasteboard;
    if ([pb stringForType:EMU3MountedImageDragType].length > 0) return NSDragOperationNone;

    NSDictionary *opts = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    if (![pb canReadObjectForClasses:@[NSURL.class] options:opts]) return NSDragOperationNone;
    // Always drop ON a directory item, never between rows
    [ov setDropItem:item dropChildIndex:NSOutlineViewDropOnItemIndex];
    BOOL isInternal = (info.draggingSource == self.sourceTableView);
    EMU3Directory *target = item ?: self.root;
    if (self.validateDropBlock) return self.validateDropBlock(target, isInternal);
    return isInternal ? NSDragOperationMove : NSDragOperationCopy;
}

- (BOOL)outlineView:(NSOutlineView *)ov
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)idx {
    if (!self.root || !self.dropReceived) return NO;
    NSPasteboard *pb = info.draggingPasteboard;
    NSArray<NSURL *(^)(void)> *imgExports = EMU3ImageDragExporters(pb);
    if (imgExports) {
        EMU3Directory *target = item ?: self.root;
        EMU3ExportDraggedImages(imgExports, ^(NSArray<NSURL *> *folders) { if (folders.count) self.dropReceived(target, folders, NO); });
        return YES;
    }
    NSDictionary *opts = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[NSURL.class] options:opts];
    if (!urls.count) return NO;
    BOOL isInternal = (info.draggingSource == self.sourceTableView);
    self.dropReceived(item ?: self.root, urls, isInternal);
    return YES;
}

@end

// ──────────────────────────────────────────────────────────────────────────────
// Content (file list)
// ──────────────────────────────────────────────────────────────────────────────

@interface EMU3SampleItem : NSObject
@property (nonatomic, weak) EMU3File *bankFile;
@property (nonatomic, assign) NSUInteger sampleIndex;
@property (nonatomic, copy) NSString *displayName;
@end

@implementation EMU3SampleItem
@end

@interface ContentController : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property (nonatomic, strong) EMU3Directory    *directory;
@property (nonatomic, strong) EMU3Filesystem   *filesystem;
@property (nonatomic, weak)   NSOutlineView    *outlineView;
@property (nonatomic, strong) NSMapTable<EMU3File *, NSArray<EMU3SampleItem *> *> *sampleItemsByBank;
@property (nonatomic, copy)   NSString *sortKey;        // column identifier, nil = disk order
@property (nonatomic, assign) BOOL sortAscending;
@property (nonatomic, strong) NSMutableArray *dragProviders;  // keep lazy pasteboard providers alive during a drag
@property (nonatomic, strong) NSHashTable<EMU3File *> *dragExportedBanks;  // banks already put on the current drag
@property (nonatomic, copy)   void (^statusUpdate)(NSString *msg);
@property (nonatomic, copy)   void (^urlsDropped)(EMU3Directory *target, NSArray<NSURL *> *urls); // files AND folders
@property (nonatomic, copy)   void (^afterImport)(void); // called on main thread after any import
@property (nonatomic, copy)   void (^onFolderNavigate)(EMU3Directory *folder);
@property (nonatomic, copy)   void (^selectionChanged)(void);
- (void)refresh;
@end

@implementation ContentController

- (EMU3Directory *)_dropTargetDirectoryForItem:(id)item outlineView:(NSOutlineView *)ov {
    if ([item isKindOfClass:[EMU3Directory class]]) return (EMU3Directory *)item;
    if ([item isKindOfClass:[NSString class]] && [item isEqualToString:@".."])
        return self.directory.parent ?: self.directory;

    id parent = [ov parentForItem:item];
    while (parent && ![parent isKindOfClass:[EMU3Directory class]]) {
        parent = [ov parentForItem:parent];
    }
    return [parent isKindOfClass:[EMU3Directory class]] ? (EMU3Directory *)parent : self.directory;
}

- (BOOL)_exportFolder:(EMU3Directory *)folder toURL:(NSURL *)folderURL error:(NSError **)error {
    if (!folder || !self.filesystem) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:error]) return NO;

    for (EMU3File *file in folder.files) {
        NSURL *fileURL = [folderURL URLByAppendingPathComponent:[EMU3FileSafeName(file.name) stringByAppendingString:@".E4B"]];
        NSError *e = nil;
        if (![self.filesystem exportFile:file toURL:fileURL error:&e])
            NSLog(@"[Drag] skipped %@: %@", file.name, e);   // one bad file must not cancel the whole drag
    }

    for (EMU3Directory *subdir in folder.subdirectories) {
        NSURL *subdirURL = [folderURL URLByAppendingPathComponent:EMU3FileSafeName(subdir.name ?: @"Folder")];
        [self _exportFolder:subdir toURL:subdirURL error:nil];
    }

    return YES;
}

- (void)refresh {
    self.sampleItemsByBank = nil;

    // Force reload of all visible cells to ensure metadata is displayed
    [self.outlineView reloadData];

    // Also invalidate rows to force re-rendering
    NSIndexSet *allRows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.outlineView.numberOfRows)];
    [self.outlineView reloadDataForRowIndexes:allRows columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.outlineView.numberOfColumns)]];
}

- (NSArray<EMU3SampleItem *> *)_sampleItemsForBankFile:(EMU3File *)file {
    if (file.fileType != EMU3FileTypeBank || !self.filesystem) return @[];
    [self.filesystem populateBankMetadata:file error:nil];

    if (!self.sampleItemsByBank) {
        self.sampleItemsByBank = [NSMapTable weakToStrongObjectsMapTable];
    }

    NSArray<EMU3SampleItem *> *cached = [self.sampleItemsByBank objectForKey:file];
    if (cached) return cached;

    NSArray<NSString *> *sampleIDs = [self.filesystem samplesFromBankFile:file error:nil];
    NSUInteger sampleCount = sampleIDs.count > 0 ? sampleIDs.count : file.sampleCount;
    NSMutableArray<EMU3SampleItem *> *items = [NSMutableArray arrayWithCapacity:sampleCount];

    for (NSUInteger idx = 0; idx < sampleCount; idx++) {
        NSString *sampleID = idx < sampleIDs.count
            ? sampleIDs[idx]
            : [NSString stringWithFormat:@"Sample_%03lu", (unsigned long)(idx + 1)];
        EMU3SampleItem *item = [[EMU3SampleItem alloc] init];
        item.bankFile = file;
        item.sampleIndex = idx;
        item.displayName = [NSString stringWithFormat:@"Sample %03lu (%@)",
                            (unsigned long)(idx + 1), sampleID];
        [items addObject:item];
    }

    [self.sampleItemsByBank setObject:items forKey:file];
    return items;
}

// ──OutlineView Data Source ──────────────────────────────────────────────

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!self.directory) return 0;

    // Root level: show ".." + subdirectories + files in current directory
    if (item == nil) {
        NSInteger count = (NSInteger)(self.directory.subdirectories.count + self.directory.allFiles.count);
        // Add ".." entry if not at filesystem root
        if (self.filesystem && self.directory != self.filesystem.rootDirectory) {
            count += 1;
        }
        return count;
    }

    // If item is a directory, show its subdirectories + files
    if ([item isKindOfClass:[EMU3Directory class]]) {
        EMU3Directory *dir = (EMU3Directory *)item;
        return (NSInteger)(dir.subdirectories.count + dir.allFiles.count);
    }

    if ([item isKindOfClass:[EMU3File class]]) {
        return (NSInteger)[self _sampleItemsForBankFile:(EMU3File *)item].count;
    }

    // Files have no children
    return 0;
}

// ── Sorting (click a column header) ──────────────────────────────────────────

- (NSArray<EMU3Directory *> *)_sortedSubdirsOf:(EMU3Directory *)dir {
    BOOL byName = [self.sortKey isEqualToString:@"Name"];
    BOOL asc = byName ? self.sortAscending : YES;   // folders only follow the Name column
    return [dir.subdirectories sortedArrayUsingComparator:^NSComparisonResult(EMU3Directory *a, EMU3Directory *b) {
        NSComparisonResult r = [a.name ?: @"" localizedStandardCompare:b.name ?: @""];
        return asc ? r : -r;
    }];
}

- (NSUInteger)_sortValueForFile:(EMU3File *)f key:(NSString *)key {
    if ([key isEqualToString:@"Presets"]) return f.presetCount;
    if ([key isEqualToString:@"Samples"]) return EMU3ResolvedSampleCount(self.filesystem, f);
    if ([key isEqualToString:@"Size"])    return f.fileSize;
    if ([key isEqualToString:@"Format"])  return (NSUInteger)f.bankFormat;
    return 0;
}

- (NSArray<EMU3File *> *)_sortedFilesOf:(EMU3Directory *)dir {
    NSArray<EMU3File *> *files = dir.allFiles;
    NSString *key = self.sortKey;
    if (key.length == 0) return files;
    BOOL asc = self.sortAscending;
    if ([key isEqualToString:@"Presets"] || [key isEqualToString:@"Samples"] || [key isEqualToString:@"Format"]) {
        for (EMU3File *f in files) [self.filesystem populateBankMetadata:f error:nil];   // cached after the first time
    }
    return [files sortedArrayUsingComparator:^NSComparisonResult(EMU3File *a, EMU3File *b) {
        NSComparisonResult r = NSOrderedSame;
        if ([key isEqualToString:@"Name"]) {
            r = [a.name ?: @"" localizedStandardCompare:b.name ?: @""];
        } else if ([key isEqualToString:@"Type"]) {
            r = [a.fileTypeString ?: @"" localizedStandardCompare:b.fileTypeString ?: @""];
        } else {
            NSUInteger x = [self _sortValueForFile:a key:key], y = [self _sortValueForFile:b key:key];
            r = x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame);
        }
        if (r == NSOrderedSame) r = [a.name ?: @"" localizedStandardCompare:b.name ?: @""];
        else if (!asc) r = -r;
        return r;
    }];
}

- (void)outlineView:(NSOutlineView *)ov sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    NSSortDescriptor *d = ov.sortDescriptors.firstObject;
    self.sortKey = d.key;
    self.sortAscending = d ? d.ascending : YES;
    [self refresh];
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!self.directory) return nil;

    if ([item isKindOfClass:[EMU3File class]]) {
        NSArray<EMU3SampleItem *> *samples = [self _sampleItemsForBankFile:(EMU3File *)item];
        return index < (NSInteger)samples.count ? samples[index] : nil;
    }

    EMU3Directory *parentDir = item ?: self.directory;

    // Special: First item is ".." to go to parent (if not at root)
    if (item == nil && self.filesystem && parentDir != self.filesystem.rootDirectory) {
        if (index == 0) {
            return @"..";  // Special marker for parent directory
        }
        index -= 1;  // Shift all other indices down by 1
    }

    NSInteger subdirCount = (NSInteger)parentDir.subdirectories.count;

    // Return subdirectories
    if (index < subdirCount) {
        return [self _sortedSubdirsOf:parentDir][index];
    }

    // Then, return files
    NSArray<EMU3File *> *files = [self _sortedFilesOf:parentDir];
    NSInteger fileIndex = index - subdirCount;
    if (fileIndex < (NSInteger)files.count) {
        return files[fileIndex];
    }

    return nil;
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    if ([item isKindOfClass:[NSString class]] && [item isEqualToString:@".."]) return NO;
    if ([item isKindOfClass:[EMU3Directory class]]) return YES;
    if ([item isKindOfClass:[EMU3File class]]) {
        return [self _sampleItemsForBankFile:(EMU3File *)item].count > 0;
    }
    return NO;
}

// ── OutlineView Delegate ────────────────────────────────────────────────

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    NSString *ident = col.identifier;
    NSTableCellView *cell = [ov makeViewWithIdentifier:ident owner:self];

    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = ident;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.frame = NSMakeRect(4, 2, col.width - 8, 16);
        tf.autoresizingMask = NSViewWidthSizable;
        tf.font = [NSFont systemFontOfSize:12];
        [cell addSubview:tf];
        cell.textField = tf;
    }

    // Handle ".." (parent directory)
    if ([item isKindOfClass:[NSString class]] && [item isEqualToString:@".."]) {
        if ([ident isEqualToString:@"Name"]) {
            NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];
            NSAttributedString *emoji = [[NSAttributedString alloc]
                initWithString:@"⬆ "
                attributes:@{NSForegroundColorAttributeName: [NSColor systemGrayColor]}];
            [attrStr appendAttributedString:emoji];
            NSAttributedString *nameStr = [[NSAttributedString alloc]
                initWithString:@".."
                attributes:@{NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]}];
            [attrStr appendAttributedString:nameStr];
            cell.textField.attributedStringValue = attrStr;
        } else {
            cell.textField.stringValue = @"";
        }
        return cell;
    }

    // Handle directories
    if ([item isKindOfClass:[EMU3Directory class]]) {
        EMU3Directory *dir = (EMU3Directory *)item;
        if ([ident isEqualToString:@"Name"]) {
            // Create attributed string with colored folder emoji
            NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];

            // Blue folder emoji
            NSAttributedString *emoji = [[NSAttributedString alloc]
                initWithString:@"📁 "
                attributes:@{NSForegroundColorAttributeName: [NSColor systemBlueColor]}];
            [attrStr appendAttributedString:emoji];

            // Folder name
            NSAttributedString *nameStr = [[NSAttributedString alloc]
                initWithString:dir.name ?: @""
                attributes:@{NSForegroundColorAttributeName: [NSColor labelColor]}];
            [attrStr appendAttributedString:nameStr];

            cell.textField.attributedStringValue = attrStr;
        } else {
            cell.textField.stringValue = @"";
        }
        return cell;
    }

    if ([item isKindOfClass:[EMU3SampleItem class]]) {
        EMU3SampleItem *sample = (EMU3SampleItem *)item;
        if ([ident isEqualToString:@"Name"]) {
            cell.textField.stringValue = sample.displayName ?: @"Sample";
        } else if ([ident isEqualToString:@"Type"]) {
            cell.textField.stringValue = @"Sample";
        } else {
            cell.textField.stringValue = @"";
        }
        return cell;
    }

    // Handle files
    EMU3File *file = (EMU3File *)item;
    if ([ident isEqualToString:@"Name"]) {
        cell.textField.stringValue = file.name ?: @"";
    } else if ([ident isEqualToString:@"Type"]) {
        cell.textField.stringValue = file.fileTypeString;
    } else if ([ident isEqualToString:@"Size"]) {
        cell.textField.stringValue = file.fileSizeString;
    } else if ([ident isEqualToString:@"Format"]) {
        if (file.bankFormat == EMU3BankFormatEmulatorThree)     cell.textField.stringValue = @"Emulator III";
        else if (file.bankFormat == EMU3BankFormatEmulator3X)   cell.textField.stringValue = @"Emulator 3X";
        else if (file.bankFormat == EMU3BankFormatESI32v3)      cell.textField.stringValue = @"ESI-32 v3";
        else if (file.bankFormat == EMU3BankFormatEmulatorIV)   cell.textField.stringValue = @"Emulator IV";
        else cell.textField.stringValue = @"—";
    } else if ([ident isEqualToString:@"Presets"]) {
        cell.textField.stringValue = file.presetCount > 0 ? @(file.presetCount).stringValue : @"—";
    } else if ([ident isEqualToString:@"Samples"]) {
        NSUInteger sc = EMU3ResolvedSampleCount(self.filesystem, file);
        cell.textField.stringValue = sc > 0 ? @(sc).stringValue : @"—";
    }

    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    if (self.selectionChanged) self.selectionChanged();
}

// Drag source — files/folders are exported to a UUID temp folder lazily, when the drop asks.
- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov pasteboardWriterForItem:(id)item {
    EMU3Filesystem *fs = self.filesystem;
    if (!fs) return nil;

    // A sample lives inside a bank, so dragging samples drags their bank (once).
    if ([item isKindOfClass:[EMU3SampleItem class]]) {
        item = ((EMU3SampleItem *)item).bankFile;
        if (!item) return nil;
    }

    BOOL isFile = [item isKindOfClass:[EMU3File class]];
    BOOL isDir  = [item isKindOfClass:[EMU3Directory class]];
    if (!isFile && !isDir) return nil;

    if (isFile) {
        if (!self.dragExportedBanks) self.dragExportedBanks = [NSHashTable weakObjectsHashTable];
        if ([self.dragExportedBanks containsObject:item]) return nil;
        [self.dragExportedBanks addObject:item];
    }

    __weak ContentController *wSelf = self;
    EMU3LazyFileURLProvider *provider = [[EMU3LazyFileURLProvider alloc] init];
    provider.exporter = ^NSURL *{
        NSURL *tempDir = [[[NSURL fileURLWithPath:NSTemporaryDirectory()]
                            URLByAppendingPathComponent:@"EMU3Drag"]
                           URLByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:tempDir
                                      withIntermediateDirectories:YES attributes:nil error:nil])
            return nil;
        if (isFile) {
            EMU3File *file = item;
            NSURL *destURL = [tempDir URLByAppendingPathComponent:[EMU3FileSafeName(file.name) stringByAppendingString:@".E4B"]];
            NSError *err = nil;
            if (![fs exportFile:file toURL:destURL error:&err]) {
                NSLog(@"Drag export failed for %@: %@", file.name, err);
                return nil;
            }
            return destURL;
        }
        EMU3Directory *folder = item;
        NSURL *folderURL = [tempDir URLByAppendingPathComponent:EMU3FileSafeName(folder.name ?: @"Folder")];
        NSError *err = nil;
        if (![wSelf _exportFolder:folder toURL:folderURL error:&err]) {
            NSLog(@"Drag folder export failed for %@: %@", folder.name, err);
            return nil;
        }
        return folderURL;
    };

    if (!self.dragProviders) self.dragProviders = [NSMutableArray array];
    [self.dragProviders addObject:provider];

    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setDataProvider:provider forTypes:@[NSPasteboardTypeFileURL]];
    return pbItem;
}

- (void)outlineView:(NSOutlineView *)ov
    draggingSession:(NSDraggingSession *)session
   willBeginAtPoint:(NSPoint)screenPoint
           forItems:(NSArray *)draggedItems {
    [self.dragExportedBanks removeAllObjects];
    [self.dragProviders removeAllObjects];
}

// Drag destination — copy dropped file URLs into the current or hovered folder.
- (NSDragOperation)outlineView:(NSOutlineView *)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {
    if (!self.filesystem || self.filesystem.isReadOnly || !self.directory) return NSDragOperationNone;

    NSPasteboard *pb = info.draggingPasteboard;
    NSDictionary *opts = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    if (![pb canReadObjectForClasses:@[NSURL.class] options:opts]) return NSDragOperationNone;

    EMU3Directory *targetDir = [self _dropTargetDirectoryForItem:item outlineView:ov];
    if (!targetDir) return NSDragOperationNone;

    [ov setDropItem:targetDir == self.directory ? nil : targetDir
    dropChildIndex:NSOutlineViewDropOnItemIndex];
    return NSDragOperationCopy;
}

- (BOOL)outlineView:(NSOutlineView *)ov
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)index {
    if (!self.filesystem || self.filesystem.isReadOnly || !self.directory) return NO;
    NSPasteboard *pb = info.draggingPasteboard;
    if ([pb stringForType:EMU3MountedImageDragType].length > 0) return NO;

    NSDictionary *opts = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    NSArray *urls = [pb readObjectsForClasses:@[NSURL.class] options:opts];
    if (!urls.count) return NO;

    EMU3Filesystem *fs = self.filesystem;
    EMU3Directory *targetDir = [self _dropTargetDirectoryForItem:item outlineView:ov];
    if (!targetDir) return NO;

    if (self.urlsDropped) {
        self.urlsDropped(targetDir, urls);
        return YES;
    }

    dispatch_async(fs.ioQueue, ^{
        __block NSUInteger ok = 0;
        __block NSError *lastErr = nil;
        for (NSURL *url in urls) {
            NSError *err = nil;
            if ([fs importFileAtURL:url toDirectory:targetDir error:&err]) ok++;
            else lastErr = err;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
            NSUInteger fail = urls.count - ok;
            if (self.statusUpdate) {
                NSString *msg = fail == 0
                    ? [NSString stringWithFormat:@"Imported %lu file(s) to %@.", ok, targetDir.name ?: @"folder"]
                    : [NSString stringWithFormat:@"Imported %lu file(s), %lu failed: %@",
                       ok, fail, lastErr.localizedDescription ?: @"unknown error"];
                self.statusUpdate(msg);
            }
            if (self.afterImport) self.afterImport();
        });
    });
    return YES;
}

@end

// ──────────────────────────────────────────────────────────────────────────────
// Main window
// ──────────────────────────────────────────────────────────────────────────────

@interface MainWindowController () <NSUserInterfaceValidations>
@property (nonatomic, strong) EMU3Filesystem           *filesystem;
@property (nonatomic, strong) MountedImagesController  *mountedImagesCtl;
@property (nonatomic, strong) NSMutableArray<EMU3Filesystem *> *mountedFilesystems;
@property (nonatomic, strong) ContentController        *contentCtl;
@property (nonatomic, strong) NSTableView              *imagesTableView;
// Top strip of the left pane: the image served to the sampler (separate from the mounts below it).
@property (nonatomic, strong) EMU3SamplerStripView     *servedStrip;
@property (nonatomic, strong) NSImageView              *servedDot;
@property (nonatomic, strong) NSTextField              *servedNameLabel;
@property (nonatomic, strong) NSTextField              *servedStateLabel;
@property (nonatomic, strong) NSTableView              *tableView;
@property (nonatomic, strong) NSTextField              *statusLabel;
@property (nonatomic, strong) NSTextField              *mountStatusLabel;
@property (nonatomic, strong) NSTextField              *diskSpaceLabel;
@property (nonatomic, strong) NSProgressIndicator      *spinner;
@property (nonatomic, strong) EMU3Directory            *currentDirectory;
@property (nonatomic, strong) NSMutableArray<EMU3Directory *> *navigationHistory;
@property (nonatomic, strong) EMU3Directory            *pendingMetadataDirectory;
@property (nonatomic, strong) NSView                   *breadcrumbView;
@property (nonatomic, strong) NSMutableArray<EMU3Directory *> *breadcrumbPath;
@property (nonatomic, strong) NSWindow                 *helpWindow;
@property (nonatomic, strong) WKWebView                *helpWebView;
// Copy / Paste clipboard (internal references + exported files on the general pasteboard)
@property (nonatomic, copy)   NSArray<EMU3File *>      *clipFiles;
@property (nonatomic, strong) EMU3Filesystem           *clipFilesystem;
// Batch copy progress sheet
// "New Image" panel
@property (nonatomic, strong) NSPopUpButton            *niVolume;
@property (nonatomic, strong) NSTextField              *niInfo;
@property (nonatomic, strong) NSTextField              *niSize;
@property (nonatomic, strong) NSPopUpButton            *niUnit;
@property (nonatomic, copy)   NSString                 *niAutoName;
@property (nonatomic, strong) NSPopUpButton            *niScsi;
@property (nonatomic, strong) NSTextField              *niName;
@property (nonatomic, strong) NSButton                 *niFormat;
@property (nonatomic, strong) NSArray<NSDictionary *>  *niVolumes;
@property (nonatomic, strong) NSWindow                 *progressSheet;
@property (nonatomic, strong) NSProgressIndicator      *progressBar;
@property (nonatomic, strong) NSTextField              *progressDetail;
@property (atomic) BOOL                                 batchCancelled;
@property (nonatomic) BOOL                              samplerMode;   // images locked while the sampler uses the card
@property (nonatomic, strong) NSMutableDictionary<NSString *, EMU3VolumeMount *> *volumeMounts;   // image path -> Finder mount
@property (nonatomic, strong) EMU3SamplerLinkController *samplerLink;   // live USB disk for the sampler
@property (nonatomic, strong) NSMutableArray<NSWindow *> *infoPanels;   // open Get Info windows
@property (nonatomic, copy) void (^batchTick)(NSString *name);
@property (nonatomic, assign) NSInteger                 clipChangeCount;
@property (nonatomic, copy)   NSArray<NSURL *>             *deleteUndoBackupURLs;
@property (nonatomic, strong) EMU3Directory                *deleteUndoDirectory;
@property (nonatomic, copy)   NSArray<EMU3Directory *>     *deleteUndoDirectories;
@property (nonatomic, copy)   NSArray<EMU3File *>          *deleteRedoFiles;
@property (nonatomic, strong) EMU3Directory                *deleteRedoDirectory;
@property (nonatomic, copy)   NSArray<EMU3Directory *>     *deleteRedoDirectories;
@property (nonatomic, strong) NSURL                        *folderUndoBackupURL;
@property (nonatomic, copy)   NSString                     *folderUndoName;
@property (nonatomic, strong) EMU3Directory                *folderUndoParentDirectory;
@property (nonatomic, copy)   NSString                     *folderRedoName;
@property (nonatomic, strong) EMU3Directory                *folderRedoParentDirectory;
@property (nonatomic, strong) EMU3Filesystem               *imageCopyUndoFilesystem;
@property (nonatomic, strong) NSURL                        *imageCopyUndoURL;
@end
// ── bluescsi.ini configurator ────────────────────────────────────────────────
// Only the settings this firmware reads from an SD card: the USB block drive (SCSI id + size) and the USB-storage
// switch. Without an SD card the board needs no ini at all (the Mac configures it over USB).
@interface EMU3IniHelper : NSObject <NSTextFieldDelegate>
@property (nonatomic, strong) NSPopUpButton *idPopup, *imagePopup;
@property (nonatomic, strong) NSTextField *mbField, *preview;
@property (nonatomic, strong) NSButton *massStorageBox, *attentionBox;
@property (nonatomic, strong) NSArray<NSNumber *> *imageMBs;   // per popup item, 0 = custom
- (void)ok:(id)sender;
- (void)cancel:(id)sender;
- (void)update:(id)sender;
- (NSString *)iniText;
@end
@implementation EMU3IniHelper
- (void)ok:(id)sender { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (long)megabytes {
    NSInteger i = self.imagePopup.indexOfSelectedItem;
    long mb = (i >= 0 && i < (NSInteger)self.imageMBs.count) ? self.imageMBs[(NSUInteger)i].longValue : 0;
    return mb > 0 ? mb : MAX(1, self.mbField.integerValue);
}
- (NSString *)iniText {
    return [NSString stringWithFormat:
        @"# bluescsi.ini for the USB-SCSI bridge firmware (made by EMU3 Disk Manager).\n"
        @"# Only needed when an SD card is in the board; without a card the Mac configures the board over USB.\n"
        @"[SCSI]\n"
        @"USBBlockDriveSCSIID=%ld\n"
        @"USBBlockDriveMB=%ld\n"
        @"EnableUSBMassStorage=%d\n"
        @"EnableUnitAttention=%d\n",
        (long)self.idPopup.indexOfSelectedItem, [self megabytes],
        self.massStorageBox.state == NSControlStateValueOn ? 0 : 1,
        self.attentionBox.state == NSControlStateValueOn ? 1 : 0];
}
- (void)update:(id)sender {
    BOOL custom = self.imagePopup.indexOfSelectedItem == (NSInteger)self.imageMBs.count - 1;
    self.mbField.enabled = custom;
    if (!custom) { long mb = [self megabytes]; self.mbField.stringValue = [NSString stringWithFormat:@"%ld", mb]; }
    self.preview.stringValue = [self iniText];
}
- (void)controlTextDidChange:(NSNotification *)n { self.preview.stringValue = [self iniText]; }
@end


@implementation MainWindowController

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0,0,1200,700)
                  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|
                            NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = @"EMU3 Disk Manager";
    win.minSize = NSMakeSize(800, 500);
    BOOL startLocked = [NSUserDefaults.standardUserDefaults boolForKey:@"SamplerMode"];
    if (startLocked) win.subtitle = @"Sampler mode: images are locked (read-only)";
    [win center];
    self = [super initWithWindow:win];
    if (self) self.samplerMode = [NSUserDefaults.standardUserDefaults boolForKey:@"SamplerMode"];
    if (self) {
        [self _buildUI];
        [self _setupKeyboardShortcuts];
        [self _setupNotificationObservers];
    }
    return self;
}

- (void)_buildUI {
    NSView *content = self.window.contentView;

    // Initialize mounted filesystems array
    self.mountedFilesystems = [NSMutableArray array];
    self.breadcrumbPath = [NSMutableArray array];
    self.navigationHistory = [NSMutableArray array];

    // ── Toolbar ──────────────────────────────────────────────────────────────
    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"MainToolbar"];
    tb.delegate = (id)self;
    tb.allowsUserCustomization = NO;
    self.window.toolbar = tb;

    // ── Split view ───────────────────────────────────────────────────────────
    NSSplitView *split = [[NSSplitView alloc] initWithFrame:content.bounds];
    split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    split.vertical = YES;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.delegate = self;
    [content addSubview:split];

    // ── LEFT PANE: Mounted Images List ────────────────────────────────────────
    NSView *leftPane = [[NSView alloc] initWithFrame:NSMakeRect(0,0,340,600)];

    NSView *mountStatusBar = [[NSView alloc] initWithFrame:NSMakeRect(0,0,340,28)];
    mountStatusBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    mountStatusBar.wantsLayer = YES;
    mountStatusBar.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];

    NSTextField *mountStatusLbl = [NSTextField labelWithString:@"No mounts"];
    mountStatusLbl.frame = NSMakeRect(8, 6, 324, 18);
    mountStatusLbl.autoresizingMask = NSViewWidthSizable;
    mountStatusLbl.font = [NSFont systemFontOfSize:11];
    mountStatusLbl.textColor = [NSColor secondaryLabelColor];
    mountStatusLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [mountStatusBar addSubview:mountStatusLbl];
    self.mountStatusLabel = mountStatusLbl;
    [leftPane addSubview:mountStatusBar];

    NSBox *mountSep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 28, 340, 1)];
    mountSep.boxType = NSBoxSeparator;
    mountSep.autoresizingMask = NSViewWidthSizable;
    [leftPane addSubview:mountSep];

    // Sampler strip at the top (always visible), a separator, then the list of mounts.
    const CGFloat stripH = 46;
    EMU3SamplerStripView *strip = [[EMU3SamplerStripView alloc] initWithFrame:NSMakeRect(0, 600 - stripH, 340, stripH)];
    self.servedStrip = strip;
    strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    NSTextField *stripCap = [NSTextField labelWithString:@"SERVED TO SAMPLER"];
    stripCap.font = [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold];
    stripCap.textColor = NSColor.tertiaryLabelColor;
    stripCap.frame = NSMakeRect(10, stripH - 16, 320, 12);
    stripCap.autoresizingMask = NSViewWidthSizable;
    NSImageView *sDot = [[NSImageView alloc] initWithFrame:NSMakeRect(10, 10, 8, 8)];
    sDot.image = [NSImage imageWithSystemSymbolName:@"circle.fill" accessibilityDescription:@"Sampler link status"];
    sDot.contentTintColor = NSColor.systemGrayColor;
    NSTextField *sName = [NSTextField labelWithString:@"Nothing served"];
    sName.font = [NSFont boldSystemFontOfSize:11];
    sName.lineBreakMode = NSLineBreakByTruncatingMiddle;
    sName.frame = NSMakeRect(24, 6, 88, 16);   // the state text sits in the middle, so the name gets the left part
    sName.autoresizingMask = NSViewNotSizable;
    NSTextField *sState = [NSTextField labelWithString:@""];
    sState.font = [NSFont systemFontOfSize:10];
    sState.textColor = NSColor.secondaryLabelColor;
    sState.alignment = NSTextAlignmentCenter;
    sState.frame = NSMakeRect(115, 6, 110, 14);   // centered in the 340 pt wide pane
    sState.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    for (NSView *v in @[stripCap, sDot, sName, sState]) [strip addSubview:v];
    self.servedDot = sDot; self.servedNameLabel = sName; self.servedStateLabel = sState;
    EMU3Tip(strip, @"The image the sampler sees as its disk. Double-click to open the Sampler Link window, or drop files and images here to copy them into it.");
    EMU3Tip(sDot, @"Grey: nothing served. Orange: waiting for the board. Yellow: board connected. Green: the sampler is using the disk.");
    NSClickGestureRecognizer *one = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(_servedStripClicked:)];
    NSClickGestureRecognizer *two = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(_servedStripDoubleClicked:)];
    two.numberOfClicksRequired = 2;
    [strip addGestureRecognizer:two]; [strip addGestureRecognizer:one];
    [leftPane addSubview:strip];
    strip.postsFrameChangedNotifications = YES;
    __weak typeof(self) wStrip = self;
    [NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification object:strip queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wStrip _refreshServedMarker]; }];
    NSBox *stripSep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 600 - stripH - 1, 340, 1)];
    stripSep.boxType = NSBoxSeparator;
    stripSep.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [leftPane addSubview:stripSep];

    NSScrollView *imagesScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,29,340,571 - stripH - 1)];
    imagesScroll.hasVerticalScroller = YES;
    imagesScroll.autoresizesSubviews = YES;
    imagesScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Tree: mounted images at the top level, their folders below.
    ClickableOutlineView *imagesTable = [[ClickableOutlineView alloc] initWithFrame:imagesScroll.bounds];
    imagesTable.headerView = nil;  // Hide headers for cleaner look
    imagesTable.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    imagesTable.usesAlternatingRowBackgroundColors = NO;
    imagesTable.rowHeight = 18;
    imagesTable.indentationPerLevel = 14;
    imagesTable.allowsMultipleSelection = YES;
    imagesTable.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    NSTableColumn *imageNameCol = [[NSTableColumn alloc] initWithIdentifier:@"Name"];
    imageNameCol.title = @"Image";
    imageNameCol.width = 320;  // Full width for image names
    [imagesTable addTableColumn:imageNameCol];
    imagesTable.outlineTableColumn = imageNameCol;

    // Don't add Size column - just show image names for cleaner look

    imagesScroll.documentView = imagesTable;
    self.imagesTableView = imagesTable;
    [leftPane addSubview:imagesScroll];
    [split addSubview:leftPane];

    // ── RIGHT PANE: File Browser ─────────────────────────────────────────────────
    NSView *rightPane = [[NSView alloc] initWithFrame:NSMakeRect(0,0,680,600)];

    // Breadcrumb state is kept for navigation, but the browser starts at the top
    // so it aligns with the mounted-images list.
    NSView *breadcrumbView = [[NSView alloc] initWithFrame:NSZeroRect];
    breadcrumbView.hidden = YES;
    self.breadcrumbView = breadcrumbView;
    [rightPane addSubview:breadcrumbView];

    // Status bar at bottom
    NSView *statusBar = [[NSView alloc] initWithFrame:NSMakeRect(0,0,680,28)];
    statusBar.autoresizingMask = NSViewWidthSizable;
    statusBar.wantsLayer = YES;
    statusBar.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];

    // Status message (left-center area)
    NSTextField *statusLbl = [NSTextField labelWithString:@"No image loaded"];
    statusLbl.frame = NSMakeRect(8, 6, 360, 18);
    statusLbl.autoresizingMask = NSViewWidthSizable;
    statusLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    statusLbl.font = [NSFont systemFontOfSize:11];
    statusLbl.textColor = [NSColor secondaryLabelColor];
    statusLbl.alignment = NSTextAlignmentLeft;
    [statusBar addSubview:statusLbl];
    self.statusLabel = statusLbl;

    // Disk space info (center of status bar, away from spinner)
    NSTextField *spaceLbl = [NSTextField labelWithString:@""];
    spaceLbl.frame = NSMakeRect(376, 6, 296, 18);   // wide enough for "Used: 123.45 GB  Free: 123.45 GB  Total: 123.45 GB"
    spaceLbl.autoresizingMask = NSViewMinXMargin;
    spaceLbl.lineBreakMode = NSLineBreakByClipping;
    spaceLbl.font = [NSFont systemFontOfSize:11];
    spaceLbl.textColor = [NSColor secondaryLabelColor];
    spaceLbl.alignment = NSTextAlignmentRight;
    [statusBar addSubview:spaceLbl];
    self.diskSpaceLabel = spaceLbl;

    [rightPane addSubview:statusBar];

    // Separator line above status bar
    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 28, 680, 1)];
    sep.boxType = NSBoxSeparator;
    sep.autoresizingMask = NSViewWidthSizable;
    [rightPane addSubview:sep];

    // Outline view (tree view) - aligned with the mounted-images list, above status bar
    NSScrollView *tableScroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, 29, 680, rightPane.frame.size.height - 29)];
    tableScroll.hasVerticalScroller = YES;
    tableScroll.hasHorizontalScroller = NO;
    tableScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    ClickableOutlineView *tv = [[ClickableOutlineView alloc] initWithFrame:tableScroll.bounds];
    tv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tv.usesAlternatingRowBackgroundColors = YES;
    tv.allowsMultipleSelection = YES;
    tv.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"Name"];
    nameCol.title = @"Name";
    nameCol.width = 220;
    nameCol.minWidth = 80;

    nameCol.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"Name" ascending:YES];

    NSTableColumn *typeCol = [[NSTableColumn alloc] initWithIdentifier:@"Type"];
    typeCol.title = @"Type";
    typeCol.width = 90;
    typeCol.minWidth = 60;

    typeCol.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"Type" ascending:YES];

    NSTableColumn *fmtCol = [[NSTableColumn alloc] initWithIdentifier:@"Format"];
    fmtCol.title = @"Format";
    fmtCol.width = 110;
    fmtCol.minWidth = 80;

    fmtCol.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"Format" ascending:YES];

    NSTableColumn *presCol = [[NSTableColumn alloc] initWithIdentifier:@"Presets"];
    presCol.title = @"Presets";
    presCol.width = 65;
    presCol.minWidth = 50;

    presCol.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"Presets" ascending:YES];

    NSTableColumn *samplesCol = [[NSTableColumn alloc] initWithIdentifier:@"Samples"];
    samplesCol.title = @"Samples";
    samplesCol.width = 70;
    samplesCol.minWidth = 55;

    samplesCol.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"Samples" ascending:YES];

    NSTableColumn *sizeCol = [[NSTableColumn alloc] initWithIdentifier:@"Size"];
    sizeCol.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"Size" ascending:YES];
    sizeCol.title = @"Size";
    sizeCol.width = 80;
    sizeCol.minWidth = 60;

    for (NSTableColumn *col in @[nameCol, typeCol, fmtCol, presCol, samplesCol, sizeCol])
        [tv addTableColumn:col];

    tableScroll.documentView = tv;
    self.tableView = tv;
    [rightPane addSubview:tableScroll];

    [split addSubview:rightPane];

    // ── Controllers ──────────────────────────────────────────────────────────
    __weak typeof(self) wSelf = self;
    __weak ClickableOutlineView *wTable = tv;

    // Set up double-click handler for outline view
    tv.onDoubleClick = ^(NSInteger row) {
        id item = [wTable itemAtRow:row];

        // Handle ".." to go to parent
        if ([item isKindOfClass:[NSString class]] && [item isEqualToString:@".."]) {
            if (wSelf.navigationHistory.count > 1) {
                [wSelf _goBackFolder:nil];
            }
            return;
        }

        // Handle regular folders
        if ([item isKindOfClass:[EMU3Directory class]]) {
            EMU3Directory *dir = (EMU3Directory *)item;
            [wSelf _navigateToDirectory:dir];
        }
    };

    // Mounted Images Controller (left pane)
    MountedImagesController *mic = [[MountedImagesController alloc] init];
    mic.sortMode = 2;   // default: mount order
    mic.outlineView = imagesTable;
    mic.internalDragSource = tv;
    imagesTable.onDeleteKey = ^{ [wSelf _deleteTreeFolders:nil]; };
    imagesTable.dataSource = mic;
    imagesTable.delegate = mic;
    mic.selectionChanged = ^(EMU3Filesystem *fs, EMU3Directory *dir) {
        // Click on an image or on a folder in the tree.
        if (fs != wSelf.filesystem) [wSelf _selectImage:fs];
        EMU3Directory *target = dir ?: fs.rootDirectory;
        if (target && target != wSelf.currentDirectory) [wSelf _navigateToDirectory:target];
        [wSelf _refreshServedMarker];
    };
    mic.itemsDropped = ^(EMU3Filesystem *fs, EMU3Directory *dir, NSArray<NSURL *> *urls, BOOL isInternal, BOOL isMove) {
        [wSelf _handleTreeDropOnFilesystem:fs directory:dir urls:urls isInternal:isInternal move:isMove];
    };
    mic.imageFolderExporter = ^BOOL(EMU3Filesystem *fs, NSURL *folderURL) {
        NSError *err = nil;
        BOOL ok = [wSelf _exportFolderTolerant:fs.rootDirectory toURL:folderURL filesystem:fs];
        NSLog(@"[ImageAsFolder] %@ -> %@ ok=%d", fs.imageURL.lastPathComponent, folderURL.path, ok);
        (void)err;
        return ok;
    };
    mic.statusUpdate = ^(NSString *msg) { wSelf.statusLabel.stringValue = msg ?: @""; };
    mic.imageCopyDropped = ^(NSURL *imageURL) {
        [wSelf _openCopiedImageAtURL:imageURL];
    };
    self.mountedImagesCtl = mic;
    self.servedStrip.dropHandler = ^BOOL(NSPasteboard *pb) { return [wSelf _dropOnServedStrip:pb]; };

    // Content Controller (right pane, file list)
    ContentController *cc = [[ContentController alloc] init];
    cc.outlineView = (NSOutlineView *)tv;
    cc.statusUpdate = ^(NSString *msg) { wSelf.statusLabel.stringValue = msg ?: @""; };
    cc.urlsDropped = ^(EMU3Directory *target, NSArray<NSURL *> *urls) {
        [wSelf _importURLs:urls toMountedFilesystem:wSelf.filesystem directory:target];
    };
    cc.selectionChanged = ^{ [wSelf _updateStatusForCurrentSelection]; };
    // Handle double-click on folders to navigate into them
    cc.onFolderNavigate = ^(EMU3Directory *folder) {
        [wSelf _navigateToDirectory:folder];
    };
    // After a drop-import, reload disk space and refresh breadcrumb
    cc.afterImport = ^{
        [wSelf _updateDiskSpaceLabel];
        [wSelf _updateStatusForCurrentSelection];
        [wSelf _updateBreadcrumb];
    };
    tv.dataSource = cc;
    tv.delegate = cc;
    self.tableView = tv;  // Keep for compatibility
    self.contentCtl = cc;

    // Content context menu - set delegate to build dynamically
    tv.menu = [[NSMenu alloc] initWithTitle:@"File"];
    tv.menu.delegate = (id)self;

    // Images table context menu
    NSMenu *imagesMenu = [[NSMenu alloc] initWithTitle:@"Image"];
    NSMenuItem *copyItem = [imagesMenu addItemWithTitle:@"Copy Image As…"
                                                 action:@selector(_copyImageAs:)
                                          keyEquivalent:@""];
    copyItem.target = self;
    NSMenuItem *unmountItem = [imagesMenu addItemWithTitle:@"Unmount"
                                                    action:@selector(_unmountImage:)
                                             keyEquivalent:@""];
    unmountItem.target = self;
    NSMenuItem *infoFolderItem = [imagesMenu addItemWithTitle:@"Get Info\u2026"
                                                       action:@selector(_showTreeFolderInfo:)
                                                keyEquivalent:@""];
    infoFolderItem.target = self;
    NSMenuItem *renFolderItem = [imagesMenu addItemWithTitle:@"Rename Folder\u2026"
                                                      action:@selector(_renameTreeFolder:)
                                               keyEquivalent:@""];
    renFolderItem.target = self;
    NSMenuItem *delFolderItem = [imagesMenu addItemWithTitle:@"Delete Folder"
                                                      action:@selector(_deleteTreeFolders:)
                                               keyEquivalent:@""];
    delFolderItem.target = self;
    [imagesMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *expItem = [imagesMenu addItemWithTitle:@"Expand All"
                                                action:@selector(expandAllInTree:)
                                         keyEquivalent:@""];
    expItem.target = self;
    NSMenuItem *colItem = [imagesMenu addItemWithTitle:@"Collapse All"
                                                action:@selector(collapseAllInTree:)
                                         keyEquivalent:@""];
    colItem.target = self;
    [imagesMenu addItem:[NSMenuItem separatorItem]];
    NSArray *sortTitles = @[@"Sort A → Z", @"Sort Z → A", @"Sort by Mount Order"];
    for (NSInteger i = 0; i < 3; i++) {
        NSMenuItem *si = [imagesMenu addItemWithTitle:sortTitles[i] action:@selector(setTreeSort:) keyEquivalent:@""];
        si.tag = i; si.target = self;
    }
    imagesTable.menu = imagesMenu;

    // Drag & drop registration — file URLs for outline view and mounted image list
    [tv registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    [tv setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    // Local drags (to the folder tree) may move files; Option copies instead.
    [tv setDraggingSourceOperationMask:NSDragOperationCopy | NSDragOperationMove forLocal:YES];
    [imagesTable registerForDraggedTypes:@[NSPasteboardTypeFileURL, EMU3MountedImageDragType]];
    [imagesTable setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [imagesTable setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];

    // Spinner (in status bar)
    NSProgressIndicator *spin = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(rightPane.frame.size.width - 30, 5, 18, 18)];
    spin.autoresizingMask = NSViewMinXMargin;
    spin.style = NSProgressIndicatorStyleSpinning;
    spin.controlSize = NSControlSizeSmall;
    spin.hidden = YES;
    [statusBar addSubview:spin];
    self.spinner = spin;

    [rightPane addSubview:statusBar];
    [split addSubview:rightPane];
}

// ──────────────────────────────────────────────────────────────────────────────
// Toolbar (NSToolbarDelegate)
// ──────────────────────────────────────────────────────────────────────────────

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)tb {
    return @[@"MountItem", @"UnmountItem", @"NewFolderItem", @"ExportItem", @"ImportItem", @"DeleteItem",
             @"UndoItem", @"HelpItem", NSToolbarFlexibleSpaceItemIdentifier];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)tb {
    return @[@"MountItem", @"UnmountItem", NSToolbarFlexibleSpaceItemIdentifier,
             @"NewFolderItem", @"ImportItem", @"ExportItem", @"DeleteItem", @"UndoItem", @"HelpItem"];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)tb itemForItemIdentifier:(NSString *)ident
    willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    if ([ident isEqualToString:@"MountItem"]) {
        item.label = @"Mount Image";
        item.paletteLabel = @"Mount Image";
        item.image = [NSImage imageWithSystemSymbolName:@"externaldrive.badge.plus" accessibilityDescription:nil];
        item.target = self; item.action = @selector(_openImage:);
    } else if ([ident isEqualToString:@"UnmountItem"]) {
        item.label = @"Unmount";
        item.paletteLabel = @"Unmount Image";
        item.image = [NSImage imageWithSystemSymbolName:@"eject" accessibilityDescription:nil];
        item.target = self; item.action = @selector(_unmountImage:);
    } else if ([ident isEqualToString:@"NewFolderItem"]) {
        item.label = @"New Folder";
        item.paletteLabel = @"New Folder";
        item.image = [NSImage imageWithSystemSymbolName:@"folder.badge.plus" accessibilityDescription:nil];
        item.target = self; item.action = @selector(_newFolder:);
    } else if ([ident isEqualToString:@"ExportItem"]) {
        item.label = @"Export";
        item.paletteLabel = @"Export File";
        item.image = [NSImage imageWithSystemSymbolName:@"square.and.arrow.up" accessibilityDescription:nil];
        item.target = self; item.action = @selector(_exportSelected:);
    } else if ([ident isEqualToString:@"ImportItem"]) {
        item.label = @"Import";
        item.paletteLabel = @"Import File";
        item.image = [NSImage imageWithSystemSymbolName:@"square.and.arrow.down" accessibilityDescription:nil];
        item.target = self; item.action = @selector(_importFile:);
    } else if ([ident isEqualToString:@"DeleteItem"]) {
        item.label = @"Delete";
        item.paletteLabel = @"Delete";
        item.image = [NSImage imageWithSystemSymbolName:@"trash" accessibilityDescription:nil];
        item.target = self; item.action = @selector(deleteSelectedItem:);
    } else if ([ident isEqualToString:@"UndoItem"]) {
        item.label = @"Undo";
        item.paletteLabel = @"Undo";
        item.image = [NSImage imageWithSystemSymbolName:@"arrow.uturn.backward" accessibilityDescription:nil];
        item.target = self; item.action = @selector(_undo:);
    } else if ([ident isEqualToString:@"HelpItem"]) {
        item.label = @"Help";
        item.paletteLabel = @"Help";
        item.image = [NSImage imageWithSystemSymbolName:@"questionmark.circle" accessibilityDescription:nil];
        item.target = self; item.action = @selector(_showHelp:);
    }
    NSDictionary *tips = @{
        @"MountItem": @"Open a disk image (.hda or .iso) and add it to the mount list.",
        @"UnmountItem": @"Close the selected image. The file itself is not touched.",
        @"NewFolderItem": @"Create a new folder in the open folder of the image.",
        @"ImportItem": @"Copy banks (.E4B) or folders from your Mac into the open folder.",
        @"ExportItem": @"Copy the selected banks or samples out of the image to your Mac.",
        @"DeleteItem": @"Delete the selected items from the image (Cmd+Z undoes it).",
        @"UndoItem": @"Undo the last delete.",
        @"HelpItem": @"Open the help.",
    };
    EMU3Tip(item, tips[ident]);
    return item;
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    SEL action = item.action;
    if (action == @selector(deleteSelectedItem:))
        return self.filesystem != nil && !self.filesystem.isReadOnly;
    if (action == @selector(_copyImageAs:))
        return self.filesystem != nil;
    if (action == @selector(_deleteTreeFolders:))
        return [self _treeFoldersForDelete].count > 0;
    if (action == @selector(_showTreeFolderInfo:))
        return [self _treeFoldersForDelete].count > 0;
    if (action == @selector(_showSelectionInfo:))
        return self.filesystem != nil && ([self _selectedFiles].count + [self _selectedFolders].count) > 0;
    if (action == @selector(_renameTreeFolder:)) {
        NSArray<EMU3Directory *> *f = [self _treeFoldersForDelete];
        return f.count == 1 && f.firstObject.parent != nil;   // one folder, never the image root
    }
    if (action == @selector(_newImage:) || action == @selector(_checkSDCard:) || action == @selector(_formatSDCard:) || action == @selector(_ejectCard:))
        return YES;
    if (action == @selector(_toggleSamplerMode:)) {
        if ([(id)item isKindOfClass:[NSMenuItem class]])
            ((NSMenuItem *)item).state = self.samplerMode ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(_formatImage:))
        return self.filesystem != nil && !self.filesystem.isReadOnly;
    if (action == @selector(setTreeSort:)) {
        if ([(id)item isKindOfClass:[NSMenuItem class]])
            ((NSMenuItem *)item).state = ((NSMenuItem *)item).tag == self.mountedImagesCtl.sortMode ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(expandAllInTree:) || action == @selector(collapseAllInTree:))
        return self.mountedImagesCtl.filesystems.count > 0;
    if (action == @selector(copy:))
        return self.filesystem != nil && ([self _selectedFiles].count > 0 || [self _selectedFolders].count > 0);
    if (action == @selector(paste:)) {
        if (!self.filesystem || self.filesystem.isReadOnly) return NO;
        return [NSPasteboard.generalPasteboard canReadObjectForClasses:@[NSURL.class]
                    options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    }
    if (action == @selector(_unmountImage:) ||
        action == @selector(_exportSelected:) ||
        action == @selector(_importFile:) ||
        action == @selector(_deleteSelected:))
        return self.filesystem != nil && !self.filesystem.isReadOnly;
    if (action == @selector(_newFolder:) ||
        action == @selector(_newFolderInSelectedFolder:) ||
        action == @selector(_deleteFolder:) ||
        action == @selector(_renameFolder:))
        return self.filesystem != nil && !self.filesystem.isReadOnly;
    if (action == @selector(_goBackFolder:))
        return self.filesystem != nil && self.currentDirectory != self.filesystem.rootDirectory;
    if (action == @selector(_undo:) || action == @selector(undo:))
        return self.deleteUndoBackupURLs.count > 0 || self.folderUndoBackupURL != nil || self.imageCopyUndoFilesystem != nil;
    if (action == @selector(_redo:) || action == @selector(redo:))
        return self.deleteRedoFiles.count > 0 || self.folderRedoName != nil;
    return YES;
}

// ──────────────────────────────────────────────────────────────────────────────
// NSSplitViewDelegate
// ──────────────────────────────────────────────────────────────────────────────

- (CGFloat)splitView:(NSSplitView *)sv constrainMinCoordinate:(CGFloat)coord ofSubviewAt:(NSInteger)idx {
    return 260;
}
- (CGFloat)splitView:(NSSplitView *)sv constrainMaxCoordinate:(CGFloat)coord ofSubviewAt:(NSInteger)idx {
    return 460;
}

// ──────────────────────────────────────────────────────────────────────────────
// Public
// ──────────────────────────────────────────────────────────────────────────────

- (void)openImageAtURL:(NSURL *)url {
    [self.spinner startAnimation:nil]; self.spinner.hidden = NO;
    self.statusLabel.stringValue = @"Opening image…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        EMU3Filesystem *fs = [[EMU3Filesystem alloc] initWithURL:url error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.spinner.hidden = YES; [self.spinner stopAnimation:nil];
            if (!fs) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Cannot Open Image";
                alert.informativeText = err.localizedDescription ?: @"Unknown error";
                [alert runModal];
                self.statusLabel.stringValue = @"Failed to open image.";
                return;
            }
            // Add to mounted filesystems and select it
            fs.locked = self.samplerMode;
            [self.mountedFilesystems addObject:fs];
            [self _updateEditGates];
            [self.mountedImagesCtl addMountedFilesystem:fs];
            [self _selectImage:fs];
            self.imageCopyUndoFilesystem = nil;
            self.imageCopyUndoURL = nil;
        });
    });
}

- (void)_openCopiedImageAtURL:(NSURL *)url {
    [self.spinner startAnimation:nil]; self.spinner.hidden = NO;
    self.statusLabel.stringValue = @"Mounting copied image...";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        EMU3Filesystem *fs = [[EMU3Filesystem alloc] initWithURL:url error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.spinner.hidden = YES; [self.spinner stopAnimation:nil];
            if (!fs) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Cannot Open Image";
                alert.informativeText = err.localizedDescription ?: @"Unknown error";
                [alert runModal];
                self.statusLabel.stringValue = @"Failed to open copied image.";
                return;
            }

            [self.mountedFilesystems addObject:fs];
            [self _updateEditGates];
            [self.mountedImagesCtl addMountedFilesystem:fs];
            [self _selectImage:fs];

            self.imageCopyUndoFilesystem = fs;
            self.imageCopyUndoURL = url;
            self.deleteUndoBackupURLs = nil;
            self.deleteUndoDirectory = nil;
            self.deleteUndoDirectories = nil;
            self.deleteRedoFiles = nil;
            self.deleteRedoDirectory = nil;
            self.deleteRedoDirectories = nil;
            self.folderUndoBackupURL = nil;
            self.folderUndoName = nil;
            self.folderUndoParentDirectory = nil;
            self.folderRedoName = nil;
            self.folderRedoParentDirectory = nil;

            self.statusLabel.stringValue = [NSString stringWithFormat:@"Mounted copied image %@.", url.lastPathComponent ?: @"image"];
        });
    });
}

// ──────────────────────────────────────────────────────────────────────────────
// Private
// ──────────────────────────────────────────────────────────────────────────────

- (void)_selectImage:(EMU3Filesystem *)fs {
    self.filesystem = fs;
    self.contentCtl.filesystem = fs;
    self.window.title = [NSString stringWithFormat:@"EMU3 Disk Manager — %@",
                         fs.imageURL.lastPathComponent];

    // Start at root directory so user can see folder hierarchy
    [self _navigateToDirectory:fs.rootDirectory];

    [self _updateDiskSpaceLabel];
    [self _updateMountStatusLabel];
}

- (void)_populateBankMetadataInDirectory:(EMU3Directory *)dir filesystem:(EMU3Filesystem *)fs {
    for (EMU3File *file in dir.allFiles) {
        if (file.fileType == EMU3FileTypeBank) [fs populateBankMetadata:file error:nil];
    }
    for (EMU3Directory *subdir in dir.subdirectories) {
        [self _populateBankMetadataInDirectory:subdir filesystem:fs];
    }
}

- (NSDictionary<NSString *, NSNumber *> *)_statsForDirectory:(EMU3Directory *)dir filesystem:(EMU3Filesystem *)fs populateMetadata:(BOOL)populateMetadata {
    NSUInteger folders = dir.subdirectories.count;
    NSUInteger banks = 0;
    NSUInteger presets = 0;
    NSUInteger samples = 0;

    for (EMU3File *file in dir.allFiles) {
        if (file.fileType == EMU3FileTypeBank) {
            if (populateMetadata && fs) [fs populateBankMetadata:file error:nil];
            banks++;
            presets += file.presetCount;
            samples += (populateMetadata && fs) ? EMU3ResolvedSampleCount(fs, file) : file.sampleCount;
        }
    }

    for (EMU3Directory *subdir in dir.subdirectories) {
        NSDictionary<NSString *, NSNumber *> *child = [self _statsForDirectory:subdir filesystem:fs populateMetadata:populateMetadata];
        folders += child[@"folders"].unsignedIntegerValue;
        banks += child[@"banks"].unsignedIntegerValue;
        presets += child[@"presets"].unsignedIntegerValue;
        samples += child[@"samples"].unsignedIntegerValue;
    }

    return @{@"folders": @(folders), @"banks": @(banks), @"presets": @(presets), @"samples": @(samples)};
}

- (NSString *)_summaryStringForStats:(NSDictionary<NSString *, NSNumber *> *)stats {
    return [NSString stringWithFormat:@"%lu folders  %lu banks  %lu presets  %lu samples",
            stats[@"folders"].unsignedIntegerValue,
            stats[@"banks"].unsignedIntegerValue,
            stats[@"presets"].unsignedIntegerValue,
            stats[@"samples"].unsignedIntegerValue];
}

- (NSDictionary<NSString *, NSNumber *> *)_statsByAdding:(NSDictionary<NSString *, NSNumber *> *)a to:(NSDictionary<NSString *, NSNumber *> *)b {
    return @{@"folders": @(a[@"folders"].unsignedIntegerValue + b[@"folders"].unsignedIntegerValue),
             @"banks": @(a[@"banks"].unsignedIntegerValue + b[@"banks"].unsignedIntegerValue),
             @"presets": @(a[@"presets"].unsignedIntegerValue + b[@"presets"].unsignedIntegerValue),
             @"samples": @(a[@"samples"].unsignedIntegerValue + b[@"samples"].unsignedIntegerValue)};
}

- (NSDictionary<NSString *, NSNumber *> *)_statsForFile:(EMU3File *)file filesystem:(EMU3Filesystem *)fs {
    if (file.fileType != EMU3FileTypeBank) {
        return @{@"folders": @0, @"banks": @0, @"presets": @0, @"samples": @0};
    }
    if (fs) [fs populateBankMetadata:file error:nil];
    return @{@"folders": @0,
             @"banks": @1,
             @"presets": @(file.presetCount),
             @"samples": @(fs ? EMU3ResolvedSampleCount(fs, file) : file.sampleCount)};
}

- (NSString *)_statusTextForDirectory:(EMU3Directory *)dir filesystem:(EMU3Filesystem *)fs {
    NSDictionary<NSString *, NSNumber *> *stats = [self _statsForDirectory:dir filesystem:fs populateMetadata:NO];
    return [NSString stringWithFormat:@"%@ — %@", dir.name ?: @"Folder", [self _summaryStringForStats:stats]];
}

- (void)_updateStatusForCurrentSelection {
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    NSIndexSet *selectedRows = ov.selectedRowIndexes;
    if (!self.filesystem || selectedRows.count == 0) {
        if (self.currentDirectory) self.statusLabel.stringValue = [self _statusTextForDirectory:self.currentDirectory filesystem:self.filesystem];
        return;
    }

    __block NSDictionary<NSString *, NSNumber *> *stats = @{@"folders": @0, @"banks": @0, @"presets": @0, @"samples": @0};
    __block NSString *singleName = nil;
    NSMutableSet<EMU3File *> *sizedFiles = [NSMutableSet set];   // every file once, even if its folder is selected too
    [selectedRows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        id item = [ov itemAtRow:(NSInteger)idx];
        NSDictionary<NSString *, NSNumber *> *itemStats = nil;
        if ([item isKindOfClass:[EMU3Directory class]]) {
            EMU3Directory *dir = (EMU3Directory *)item;
            [sizedFiles addObjectsFromArray:dir.allFiles];
            itemStats = [self _statsForDirectory:dir filesystem:self.filesystem populateMetadata:NO];
            if (selectedRows.count == 1) singleName = dir.name ?: @"Folder";
        } else if ([item isKindOfClass:[EMU3File class]]) {
            EMU3File *file = (EMU3File *)item;
            [sizedFiles addObject:file];
            itemStats = [self _statsForFile:file filesystem:self.filesystem];
            if (selectedRows.count == 1) singleName = file.name ?: @"File";
        } else if ([item isKindOfClass:[EMU3SampleItem class]]) {
            itemStats = @{@"folders": @0, @"banks": @0, @"presets": @0, @"samples": @1};
            if (selectedRows.count == 1) singleName = @"Sample";
        }
        if (itemStats) stats = [self _statsByAdding:stats to:itemStats];
    }];

    NSString *label = selectedRows.count == 1 ? (singleName ?: @"Selection") : [NSString stringWithFormat:@"%lu selected", (unsigned long)selectedRows.count];
    NSString *summary = [self _summaryStringForStats:stats];
    if (sizedFiles.count > 0) {
        unsigned long long clusterBytes = (unsigned long long)self.filesystem.clusterBlocks * EMU3_BLOCK_SIZE;
        unsigned long long data = 0, onDisk = 0;
        for (EMU3File *f in sizedFiles) {
            data += f.fileSize;
            onDisk += clusterBytes ? MAX(1ULL, ((unsigned long long)f.fileSize + clusterBytes - 1) / clusterBytes) * clusterBytes : f.fileSize;
        }
        summary = [summary stringByAppendingFormat:@" — %@", EMU3SizeString(data)];
        if (onDisk != data) summary = [summary stringByAppendingFormat:@" (%@ on disk)", EMU3SizeString(onDisk)];
    }
    self.statusLabel.stringValue = [NSString stringWithFormat:@"%@ — %@", label, summary];
}

- (void)_updateMountStatusLabel {
    if (self.mountedFilesystems.count == 0) {
        self.mountStatusLabel.stringValue = @"No mounts";
        return;
    }

    EMU3Filesystem *fs = self.filesystem ?: self.mountedFilesystems.firstObject;
    NSDictionary<NSString *, NSNumber *> *stats = [self _statsForDirectory:fs.rootDirectory filesystem:fs populateMetadata:NO];
    NSString *mountName = fs.imageURL.lastPathComponent.stringByDeletingPathExtension ?: @"Mount";
    self.mountStatusLabel.stringValue = [NSString stringWithFormat:@"%@ — %@",
                                         mountName,
                                         [self _summaryStringForStats:stats]];
}

- (void)_navigateToDirectory:(EMU3Directory *)dir {
    NSLog(@"[NAV] Navigating to: %@", dir.name);
    NSLog(@"[NAV]   - Subdirs: %lu", (unsigned long)dir.subdirectories.count);
    NSLog(@"[NAV]   - Files: %lu", (unsigned long)dir.allFiles.count);

    self.currentDirectory = dir;
    self.contentCtl.directory = dir;
    self.pendingMetadataDirectory = dir;

    // Add to navigation history (for back button)
    if (!self.navigationHistory) {
        self.navigationHistory = [NSMutableArray array];
    }
    [self.navigationHistory addObject:dir];
    NSLog(@"[NAV] History depth: %lu", (unsigned long)self.navigationHistory.count);

    // Show files immediately (without metadata initially)
    [self.contentCtl refresh];

    // Update breadcrumb
    [self _updateBreadcrumb];

    // Keep the folder tree on the left in sync with the folder shown on the right
    [self.mountedImagesCtl selectFilesystem:self.filesystem directory:dir];

    EMU3Filesystem *fs = self.filesystem;
    EMU3Directory *targetDir = dir;
    dispatch_async(fs.ioQueue, ^{
        [self _populateBankMetadataInDirectory:targetDir filesystem:fs];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.pendingMetadataDirectory == targetDir) {
                [self.contentCtl refresh];
                [self _updateStatusForCurrentSelection];
                [self _updateMountStatusLabel];
            }
        });
    });

    [self _updateStatusForCurrentSelection];
    [self _updateMountStatusLabel];
}

- (void)_updateBreadcrumb {
    // Clear existing breadcrumb buttons
    for (NSView *subview in [self.breadcrumbView.subviews copy]) {
        [subview removeFromSuperview];
    }

    EMU3Filesystem *fs = self.filesystem;
    EMU3Directory *current = self.currentDirectory;
    if (!fs || !current) {
        // If no image loaded, show empty breadcrumb
        NSTextField *label = [NSTextField labelWithString:@"No image loaded"];
        label.frame = NSMakeRect(8, 8, self.breadcrumbView.frame.size.width - 16, 16);
        label.font = [NSFont systemFontOfSize:11];
        label.textColor = [NSColor tertiaryLabelColor];
        [self.breadcrumbView addSubview:label];
        return;
    }

    CGFloat x = 8;

    // Build breadcrumb path: ImageName > Dir1 > Dir2 > ...
    NSMutableArray<EMU3Directory *> *pathComponents = [NSMutableArray array];

    // Collect path from current directory up to root
    EMU3Directory *dir = current;
    while (dir && dir != fs.rootDirectory) {
        [pathComponents insertObject:dir atIndex:0];
        // Find parent directory by traversing from root
        dir = [self _findParentOf:dir inDirectory:fs.rootDirectory];
    }

    // Add root
    [pathComponents insertObject:fs.rootDirectory atIndex:0];

    // Create clickable breadcrumb buttons
    for (NSInteger i = 0; i < pathComponents.count; i++) {
        EMU3Directory *pathDir = pathComponents[i];
        NSString *btnTitle = (i == 0) ? fs.imageURL.lastPathComponent : pathDir.name;

        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(x, 6, 100, 24)];
        btn.title = btnTitle;
        btn.bezelStyle = NSBezelStyleSmallSquare;
        btn.font = [NSFont systemFontOfSize:11];

        // Use a target that captures the directory to navigate to
        btn.target = self;
        btn.action = @selector(_navigationBreadcrumbClicked:);
        btn.tag = i;  // Store index for debugging

        // Store directory reference in tooltip (hacky but works)
        btn.toolTip = [NSString stringWithFormat:@"%p", (void *)pathDir];

        [self.breadcrumbView addSubview:btn];
        x += 104;

        // Add separator between segments (except after last)
        if (i < pathComponents.count - 1) {
            NSTextField *sep = [NSTextField labelWithString:@">"];
            sep.frame = NSMakeRect(x - 6, 8, 10, 16);
            sep.font = [NSFont systemFontOfSize:11];
            sep.textColor = [NSColor tertiaryLabelColor];
            sep.alignment = NSTextAlignmentCenter;
            [self.breadcrumbView addSubview:sep];
        }
    }

    // Store path components for breadcrumb navigation
    self.breadcrumbPath = [pathComponents mutableCopy];
}

- (BOOL)_openSelectedFolderOrParent {
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    NSInteger row = ov.selectedRow;
    if (row < 0) return NO;

    id item = [ov itemAtRow:row];
    if ([item isKindOfClass:[NSString class]] && [item isEqualToString:@".."]) {
        if (self.navigationHistory.count > 1) {
            [self _goBackFolder:nil];
            return YES;
        }
        return NO;
    }

    if ([item isKindOfClass:[EMU3Directory class]]) {
        EMU3Directory *dir = (EMU3Directory *)item;
        [self _navigateToDirectory:dir];
        return YES;
    }

    return NO;
}

- (void)_updateDiskSpaceLabel {
    EMU3Filesystem *fs = self.filesystem;
    if (!fs) { self.diskSpaceLabel.stringValue = @""; return; }
    unsigned long long used = (unsigned long long)fs.usedBlocks * EMU3_BLOCK_SIZE;
    unsigned long long free_ = (unsigned long long)fs.freeBlocks * EMU3_BLOCK_SIZE;
    self.diskSpaceLabel.stringValue = [NSString stringWithFormat:@"Used: %@  Free: %@  Total: %@",
                                       EMU3FormatBytes(used), EMU3FormatBytes(free_), EMU3FormatBytes(used + free_)];
    [self _updateMountStatusLabel];
    // Folders may have changed (created, renamed, deleted): refresh the tree on the left
    [self.mountedImagesCtl reloadData];
}

- (NSMenu *)_buildContextMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"File"];

    // Get selected item to determine if it's a file or folder
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    NSInteger row = ov.selectedRow;
    id selectedItem = (row >= 0) ? [ov itemAtRow:row] : nil;
    BOOL isFolder = [selectedItem isKindOfClass:[EMU3Directory class]];
    BOOL isFile = [selectedItem isKindOfClass:[EMU3File class]];

    // File operations
    if (isFile) {
        [menu addItemWithTitle:@"Copy"            action:@selector(copy:)             keyEquivalent:@""];
        [menu addItemWithTitle:@"Paste"           action:@selector(paste:)            keyEquivalent:@""];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"Export to Mac…"  action:@selector(_exportSelected:)  keyEquivalent:@""];
        [menu addItemWithTitle:@"Export Samples…"  action:@selector(_exportSamples:)  keyEquivalent:@""];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"Rename…"          action:@selector(_renameSelected:)  keyEquivalent:@""];
        [menu addItemWithTitle:@"Copy to…"         action:@selector(_copyToDir:)       keyEquivalent:@""];
        [menu addItemWithTitle:@"Move to…"         action:@selector(_moveToDir:)       keyEquivalent:@""];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"Delete"           action:@selector(_deleteSelected:)  keyEquivalent:@""];
    }
    // Folder operations
    else if (isFolder) {
        [menu addItemWithTitle:@"Paste"              action:@selector(paste:)                     keyEquivalent:@""];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"New Folder Inside…" action:@selector(_newFolderInSelectedFolder:) keyEquivalent:@""];
        [menu addItemWithTitle:@"Rename Folder…"     action:@selector(_renameFolder:)             keyEquivalent:@""];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"Delete Folder"      action:@selector(_deleteFolder:)             keyEquivalent:@""];
    }
    // No selection or other item types
    else {
        [menu addItemWithTitle:@"Paste"            action:@selector(paste:)            keyEquivalent:@""];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"New Folder…"      action:@selector(_newFolder:)       keyEquivalent:@""];
    }

    if (isFile || isFolder) {
        [menu insertItem:[NSMenuItem separatorItem] atIndex:0];
        [menu insertItemWithTitle:@"Get Info\u2026" action:@selector(_showSelectionInfo:) keyEquivalent:@"" atIndex:0];
    }

    for (NSMenuItem *item in menu.itemArray) item.target = self;
    return menu;
}

// ──────────────────────────────────────────────────────────────────────────────
// NSMenuDelegate - Build context menu dynamically before showing
// ──────────────────────────────────────────────────────────────────────────────

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == self.tableView.menu) {
        // Clear old items
        while (menu.itemArray.count > 0) {
            [menu removeItemAtIndex:0];
        }

        // Build fresh menu based on current selection
        NSMenu *freshMenu = [self _buildContextMenu];
        for (NSMenuItem *item in freshMenu.itemArray) {
            [menu addItem:[[NSMenuItem alloc] initWithTitle:item.title action:item.action keyEquivalent:item.keyEquivalent]];
            menu.itemArray.lastObject.target = self;
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Actions
// ──────────────────────────────────────────────────────────────────────────────

- (void)_openImage:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[];
    panel.allowsOtherFileTypes = YES;
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.message = @"Select one or more E-MU Sampler disk images (.hda)";
    panel.prompt  = @"Mount";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        for (NSURL *url in [panel.URLs copy])
            [self openImageAtURL:url];
    }];
}

// Folder rows (not images) of the tree that a delete should act on: the selection, or the
// right-clicked row when it is outside the selection. Folders inside a selected folder are dropped.
- (NSArray<EMU3Directory *> *)_treeFoldersForDelete {
    NSOutlineView *tree = (NSOutlineView *)self.imagesTableView;
    NSIndexSet *rows = tree.selectedRowIndexes;
    NSInteger clicked = tree.clickedRow;
    if (clicked >= 0 && ![rows containsIndex:(NSUInteger)clicked])
        rows = [NSIndexSet indexSetWithIndex:(NSUInteger)clicked];
    NSMutableArray<EMU3Directory *> *all = [NSMutableArray array];
    [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        id item = [tree itemAtRow:(NSInteger)idx];
        if ([item isKindOfClass:[EMU3Directory class]]) [all addObject:item];
    }];
    NSMutableArray<EMU3Directory *> *top = [NSMutableArray array];
    for (EMU3Directory *d in all) {
        BOOL nested = NO;
        for (EMU3Directory *a = d.parent; a; a = a.parent) if ([all containsObject:a]) { nested = YES; break; }
        if (!nested) [top addObject:d];
    }
    return top;
}

- (EMU3Filesystem *)_filesystemOwningDirectory:(EMU3Directory *)d {
    EMU3Directory *root = d;
    while (root.parent) root = root.parent;
    for (EMU3Filesystem *fs in self.mountedFilesystems) if (fs.rootDirectory == root) return fs;
    return nil;
}

// Left pane ▸ Rename Folder…
- (void)_renameTreeFolder:(id)sender {
    NSArray<EMU3Directory *> *sel = [self _treeFoldersForDelete];
    if (sel.count != 1) { NSBeep(); return; }
    EMU3Directory *folder = sel.firstObject;
    EMU3Filesystem *fs = [self _filesystemOwningDirectory:folder];
    if (!fs || !folder.parent) { NSBeep(); return; }
    if (fs.isReadOnly) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Read-Only Image";
        a.informativeText = [NSString stringWithFormat:@"\"%@\" is on an image that is opened read-only (sampler mode or a locked file) and cannot be modified.", folder.name ?: @"Folder"];
        [a runModal];
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Rename Folder";
    alert.informativeText = @"Enter a new folder name (max 15 characters):";
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    input.stringValue = folder.name ?: @"";
    alert.accessoryView = input;
    alert.window.initialFirstResponder = input;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        NSString *newName = [input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (newName.length == 0 || [newName isEqualToString:folder.name]) return;
        if (newName.length > 15) newName = [newName substringToIndex:15];
        dispatch_async(fs.ioQueue, ^{
            NSError *err = nil;
            BOOL ok = [fs renameDirectory:folder newName:newName error:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) {
                    NSAlert *e = [[NSAlert alloc] init];
                    e.alertStyle = NSAlertStyleWarning;
                    e.messageText = @"Could not rename the folder";
                    e.informativeText = err.localizedDescription ?: @"Unknown error";
                    [e beginSheetModalForWindow:self.window completionHandler:nil];
                    return;
                }
                [self.mountedImagesCtl reloadData];
                [self.contentCtl refresh];
                [self _updateBreadcrumb];
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Folder renamed to \"%@\".", newName];
            });
        });
    }];
}

- (void)_deleteTreeFolders:(id)sender {
    NSArray<EMU3Directory *> *folders = [[self _treeFoldersForDelete] copy];
    if (folders.count == 0) { NSBeep(); return; }
    for (EMU3Directory *d in folders) {
        EMU3Filesystem *fs = [self _filesystemOwningDirectory:d];
        if (!fs || fs.isReadOnly) {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"Read-Only Image";
            a.informativeText = [NSString stringWithFormat:@"\"%@\" is on an image that is opened read-only and cannot be modified.", d.name ?: @"Folder"];
            [a runModal];
            return;
        }
    }

    NSUInteger items = 0;
    for (EMU3Directory *d in folders) items += d.files.count + d.subdirectories.count;
    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = folders.count == 1
        ? [NSString stringWithFormat:@"Delete folder \"%@\"?", folders.firstObject.name]
        : [NSString stringWithFormat:@"Delete %lu folders?", (unsigned long)folders.count];
    confirm.informativeText = items > 0
        ? @"Everything inside the folder(s) is deleted too. This cannot be undone."
        : @"This cannot be undone.";
    [confirm addButtonWithTitle:@"Delete"];
    [confirm addButtonWithTitle:@"Cancel"];
    confirm.buttons[0].hasDestructiveAction = YES;
    [confirm beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        self.statusLabel.stringValue = @"Deleting…";
        dispatch_group_t group = dispatch_group_create();
        __block NSUInteger ok = 0, fail = 0;
        __block NSError *lastErr = nil;
        for (EMU3Directory *d in folders) {
            EMU3Filesystem *fs = [self _filesystemOwningDirectory:d];
            EMU3Directory *parent = d.parent ?: fs.rootDirectory;
            dispatch_group_async(group, fs.ioQueue, ^{
                NSError *err = nil;
                BOOL done = [fs deleteDirectory:d fromParent:parent error:&err];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (done) ok++; else { fail++; lastErr = err; }
                });
            });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            // If the open folder was deleted (or lives inside one), go back to its image root.
            BOOL lost = NO;
            for (EMU3Directory *a = self.currentDirectory; a; a = a.parent)
                if ([folders containsObject:a]) { lost = YES; break; }
            if (lost && self.filesystem) [self _navigateToDirectory:self.filesystem.rootDirectory];
            [self.contentCtl refresh];
            [self _updateDiskSpaceLabel];
            [self _updateBreadcrumb];
            [self.mountedImagesCtl reloadData];
            NSString *msg = [NSString stringWithFormat:@"Deleted %lu folder(s).", (unsigned long)ok];
            if (fail > 0) msg = [msg stringByAppendingFormat:@" %lu failed: %@", (unsigned long)fail,
                                 lastErr.localizedDescription ?: @"unknown error"];
            self.statusLabel.stringValue = msg;
        });
    }];
}

- (void)setTreeSort:(NSMenuItem *)sender {
    self.mountedImagesCtl.sortMode = sender.tag;
    [self.mountedImagesCtl reloadData];
}

// Tools > Format Image…: erases the image that is selected in the tree.
- (void)_formatImage:(id)sender {
    EMU3Filesystem *fs = self.filesystem;
    if (!fs || fs.isReadOnly) { NSBeep(); return; }
    NSString *name = fs.imageURL.lastPathComponent ?: @"image";
    NSUInteger folders = 0, banks = 0;
    NSMutableArray<EMU3Directory *> *stack = [NSMutableArray arrayWithObject:fs.rootDirectory];
    while (stack.count) {
        EMU3Directory *d = stack.lastObject; [stack removeLastObject];
        banks += d.files.count;
        for (EMU3Directory *s in d.subdirectories) { folders++; [stack addObject:s]; }
    }
    unsigned long long size = (unsigned long long)fs.totalBlocks * EMU3_BLOCK_SIZE;
    NSAlert *a = [[NSAlert alloc] init];
    a.alertStyle = NSAlertStyleCritical;
    a.messageText = [NSString stringWithFormat:@"Format \"%@\"?", name];
    a.informativeText = [NSString stringWithFormat:
        @"This ERASES everything on the image (%@): %lu folder(s) and %lu bank(s) will be lost and cannot be recovered.\n\n"
        @"A new empty EOS file system is written, using the same layout the sampler creates. "
        @"This is verified for 1 GB and 14 GB images; for other sizes, formatting on the sampler itself is the safest choice.",
        EMU3SizeString(size), (unsigned long)folders, (unsigned long)banks];
    [a addButtonWithTitle:@"Cancel"];
    [a addButtonWithTitle:@"Format"];
    a.buttons.lastObject.hasDestructiveAction = YES;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertSecondButtonReturn) return;
        self.statusLabel.stringValue = @"Formatting…";
        dispatch_async(fs.ioQueue, ^{
            NSError *err = nil;
            BOOL ok = [fs formatWithError:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) {
                    self.statusLabel.stringValue = @"Format failed.";
                    if (err) [[NSAlert alertWithError:err] beginSheetModalForWindow:self.window completionHandler:nil];
                    return;
                }
                [self _navigateToDirectory:fs.rootDirectory];
                [self.contentCtl refresh];
                [self _updateDiskSpaceLabel];
                [self.mountedImagesCtl reloadData];
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Formatted %@. The image is empty.", name];
            });
        });
    }];
}


#pragma mark - Tools: SD card check and new image

// Mounted local volumes (system disk and network shares left out) with size / format details.
- (NSArray<NSDictionary *> *)_mountedVolumeInfos {
    NSArray *keys = @[NSURLVolumeNameKey, NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityKey,
                      NSURLVolumeLocalizedFormatDescriptionKey, NSURLVolumeIsInternalKey,
                      NSURLVolumeIsLocalKey, NSURLVolumeIsRootFileSystemKey, NSURLVolumeIsRemovableKey];
    NSMutableArray *out = [NSMutableArray array];
    for (NSURL *u in [NSFileManager.defaultManager mountedVolumeURLsIncludingResourceValuesForKeys:keys
                                                                                           options:NSVolumeEnumerationSkipHiddenVolumes]) {
        NSDictionary *v = [u resourceValuesForKeys:keys error:nil];
        if ([v[NSURLVolumeIsRootFileSystemKey] boolValue] || ![v[NSURLVolumeIsLocalKey] boolValue]) continue;
        if ([u.path hasPrefix:@"/System/"] || [u.path hasPrefix:@"/private/"]) continue;
        NSString *fmt = v[NSURLVolumeLocalizedFormatDescriptionKey] ?: @"?";
        NSString *low = fmt.lowercaseString;
        BOOL fat32 = ([low containsString:@"fat"] && ![low containsString:@"exfat"]);
        [out addObject:@{ @"url": u,
                          @"name": v[NSURLVolumeNameKey] ?: u.lastPathComponent,
                          @"format": fmt,
                          @"fat32": @(fat32),
                          @"total": v[NSURLVolumeTotalCapacityKey] ?: @0,
                          @"free": v[NSURLVolumeAvailableCapacityKey] ?: @0,
                          @"external": @(![v[NSURLVolumeIsInternalKey] boolValue] || [v[NSURLVolumeIsRemovableKey] boolValue]) }];
    }
    return out;
}

- (NSString *)_describeVolume:(NSDictionary *)v {
    unsigned long long total = [v[@"total"] unsignedLongLongValue], free = [v[@"free"] unsignedLongLongValue];
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@: %@ total, %@ free (host volume: %@).",
                          v[@"name"], EMU3SizeString(total), EMU3SizeString(free), v[@"format"]];
    if ([v[@"fat32"] boolValue])
        [s appendString:@"\nFAT32 cannot hold files of 4 GB or more: erase the card as exFAT to use bigger images."];
    if (total > 0 && total < 1000ULL * 1000 * 1000)
        [s appendString:@"\nVery small card."];
    return s;
}

// Tools > Check SD Card…
- (void)_checkSDCard:(id)sender {
    NSArray *vols = [self _mountedVolumeInfos];
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *v in vols) {
        if (![v[@"external"] boolValue]) continue;
        [text appendFormat:@"%@\n\n", [self _describeVolume:v]];
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = text.length ? @"Inserted disks and cards" : @"No SD card found";
    a.informativeText = text.length ? [text copy]
                                    : @"Insert an SD card (or card reader) and try again.";
    [a addButtonWithTitle:@"OK"];
    [a beginSheetModalForWindow:self.window completionHandler:nil];
}

- (NSDictionary *)_selectedNewImageVolume {
    NSInteger i = self.niVolume.indexOfSelectedItem;
    return (i >= 0 && i < (NSInteger)self.niVolumes.count) ? self.niVolumes[i] : nil;
}

// The work folder: the first line of ~/Library/Application Support/EMU3/watch.txt, which the login auto-mount agent watches.
- (NSString *)_watchFilePath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/EMU3/watch.txt"];
}

- (NSURL *)_imagesFolder {
    NSString *txt = [NSString stringWithContentsOfFile:[self _watchFilePath] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (t.length) return [NSURL fileURLWithPath:t.stringByExpandingTildeInPath isDirectory:YES];
    }
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"EMU3 Images"] isDirectory:YES];
}


- (void)_createBlueSCSIIni:(id)sender {
    EMU3IniHelper *h = [[EMU3IniHelper alloc] init];
    const CGFloat W = 520, H = 372;
    NSPanel *w = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Create bluescsi.ini";
    NSView *c = w.contentView;
    NSTextField *intro = [NSTextField wrappingLabelWithString:@"The board runs without a bluescsi.ini when no SD card is in it. Use this file only for an SD card in the board: it tells the firmware which disk to present to the sampler (served by this Mac over USB) and keeps the card from showing up as a USB drive."];
    intro.font = [NSFont systemFontOfSize:11]; intro.textColor = NSColor.secondaryLabelColor;
    intro.frame = NSMakeRect(20, H - 78, W - 40, 60);

    NSTextField *l1 = [NSTextField labelWithString:@"SCSI ID of the disk:"]; l1.frame = NSMakeRect(20, H - 110, 140, 18);
    h.idPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, H - 114, 70, 26) pullsDown:NO];
    for (int i = 0; i < 8; i++) [h.idPopup addItemWithTitle:[NSString stringWithFormat:@"%d", i]];
    [h.idPopup selectItemAtIndex:[EMU3BlockServer boardSCSIID]];
    h.idPopup.target = h; h.idPopup.action = @selector(update:);
    EMU3Tip(h.idPopup, @"The SCSI ID the sampler addresses the disk at. Default 7 (the E64 sampler itself is ID 6).");

    NSTextField *l2 = [NSTextField labelWithString:@"Disk size from:"]; l2.frame = NSMakeRect(20, H - 146, 140, 18);
    h.imagePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, H - 150, 335, 26) pullsDown:NO];
    NSMutableArray<NSNumber *> *mbs = [NSMutableArray array];
    NSString *servedPath = self.samplerLink.activeServer.imageURL.path;
    NSInteger servedIdx = -1;
    for (EMU3Filesystem *fs in self.mountedFilesystems) {
        unsigned long long sz = [[NSFileManager.defaultManager attributesOfItemAtPath:fs.imageURL.path error:nil] fileSize];
        long mb = (long)(sz / (1024 * 1024));
        [h.imagePopup addItemWithTitle:[NSString stringWithFormat:@"%@  (%ld MB)", fs.imageURL.lastPathComponent, mb]];
        [mbs addObject:@(mb)];
        if (servedPath && [fs.imageURL.path isEqualToString:servedPath]) servedIdx = (NSInteger)mbs.count - 1;
    }
    [h.imagePopup addItemWithTitle:@"Custom size…"];
    [mbs addObject:@0];
    h.imageMBs = mbs;
    h.imagePopup.target = h; h.imagePopup.action = @selector(update:);
    if (servedIdx >= 0) [h.imagePopup selectItemAtIndex:servedIdx];
    EMU3Tip(h.imagePopup, @"The size the board reports to the sampler. It must match the image you serve; pick the image, or enter a size.");

    NSTextField *l3 = [NSTextField labelWithString:@"Size in MB:"]; l3.frame = NSMakeRect(20, H - 182, 140, 18);
    h.mbField = [NSTextField textFieldWithString:@"14336"];
    h.mbField.frame = NSMakeRect(165, H - 186, 110, 24);
    h.mbField.delegate = h;

    h.massStorageBox = [NSButton checkboxWithTitle:@"Do not show the SD card as a USB drive (recommended)" target:h action:@selector(update:)];
    h.massStorageBox.state = NSControlStateValueOn;
    h.massStorageBox.frame = NSMakeRect(20, H - 214, W - 40, 20);
    EMU3Tip(h.massStorageBox, @"Without this the board opens its SD card as a USB drive on the Mac and the SCSI side waits until the card is ejected.");
    h.attentionBox = [NSButton checkboxWithTitle:@"Tell the sampler when the Mac changed the disk" target:h action:@selector(update:)];
    h.attentionBox.state = NSControlStateValueOn;
    h.attentionBox.frame = NSMakeRect(20, H - 238, W - 40, 20);

    h.preview = [NSTextField wrappingLabelWithString:@""];
    h.preview.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    h.preview.frame = NSMakeRect(20, 56, W - 40, H - 250 - 56 + 6);
    h.preview.textColor = NSColor.secondaryLabelColor;
    NSButton *ok = [NSButton buttonWithTitle:@"Save…" target:h action:@selector(ok:)];
    ok.bezelStyle = NSBezelStyleRegularSquare; ok.keyEquivalent = @"\r"; ok.frame = NSMakeRect(W - 120, 14, 100, 32);
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:h action:@selector(cancel:)];
    cancel.bezelStyle = NSBezelStyleRegularSquare; cancel.keyEquivalent = @"\e"; cancel.frame = NSMakeRect(W - 228, 14, 100, 32);
    for (NSView *v in @[intro, l1, h.idPopup, l2, h.imagePopup, l3, h.mbField, h.massStorageBox, h.attentionBox, h.preview, ok, cancel]) [c addSubview:v];
    [h update:nil];
    [w center];
    NSModalResponse r = [NSApp runModalForWindow:w];
    [w orderOut:nil];
    if (r != NSModalResponseOK) return;

    NSString *text = [h iniText];
    NSSavePanel *sp = [NSSavePanel savePanel];
    sp.nameFieldStringValue = @"bluescsi.ini";
    sp.message = @"Save bluescsi.ini in the root of the board's SD card.";
    for (NSString *v in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@"/Volumes" error:nil])
        if ([v.lowercaseString isEqualToString:@"bluescsi"]) sp.directoryURL = [NSURL fileURLWithPath:@"/Volumes/BLUESCSI" isDirectory:YES];
    if ([sp runModal] != NSModalResponseOK) return;
    NSError *err = nil;
    if ([text writeToURL:sp.URL atomically:YES encoding:NSUTF8StringEncoding error:&err])
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Saved %@.", sp.URL.path];
    else {
        NSAlert *a = [[NSAlert alloc] init]; a.messageText = @"Could not save bluescsi.ini";
        a.informativeText = err.localizedDescription ?: @""; [a runModal];
    }
}

// Tools > Update Board Firmware…
// Flow: log port gets "b" then "y" -> the board reboots into its UF2 drive (RP2350) -> copy the .uf2 -> the board restarts.
- (void)_updateBoardFirmware:(id)sender {
    NSString *uf2 = EMU3RunFirmwareDialog();
    if (uf2) [self _flashFirmwareAtPath:uf2];
}

- (void)_flashFirmwareAtPath:(NSString *)uf2 {
    self.statusLabel.stringValue = @"Updating the board firmware…";
    __weak typeof(self) wSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *vol = @"/Volumes/RP2350";
        NSString *err = nil;
        void (^status)(NSString *) = ^(NSString *m) { dispatch_async(dispatch_get_main_queue(), ^{ wSelf.statusLabel.stringValue = m; [wSelf.samplerLink logLine:m]; }); };
        if (![fm fileExistsAtPath:vol]) {
            // Log port = the first CDC interface (device name ends in 1). b = bootloader request, y = confirm.
            NSString *port = nil;
            for (NSString *n in [fm contentsOfDirectoryAtPath:@"/dev" error:nil])
                if ([n hasPrefix:@"cu.usbmodem"] && [n hasSuffix:@"1"]) { port = [@"/dev" stringByAppendingPathComponent:n]; break; }
            if (!port) err = @"The board's log port was not found. Is the BlueSCSI plugged in over USB?";
            else {
                int fd = open(port.fileSystemRepresentation, O_RDWR | O_NONBLOCK | O_NOCTTY);
                if (fd < 0) err = @"Could not open the board's log port.";
                else {
                    status(@"Asking the board to restart into its update mode…");
                    (void)!write(fd, "b", 1); usleep(700000);
                    char junk[256]; while (read(fd, junk, sizeof junk) > 0) {}
                    (void)!write(fd, "y", 1); usleep(300000);
                    close(fd);
                }
            }
            for (int i = 0; !err && i < 40 && ![fm fileExistsAtPath:vol]; i++) usleep(500000);
            if (!err && ![fm fileExistsAtPath:vol]) err = @"The board did not show its update drive (RP2350). Hold BOOTSEL while plugging it in and try again.";
        }
        if (!err) {
            status(@"Copying the firmware to the board…");
            NSString *dst = [vol stringByAppendingPathComponent:@"firmware.uf2"];
            NSError *ce = nil;
            BOOL ok = [fm copyItemAtPath:uf2 toPath:dst error:&ce];
            // The board reboots as soon as the last block is written, so a late error with the drive gone is fine.
            if (!ok && [fm fileExistsAtPath:vol]) err = [NSString stringWithFormat:@"Copy failed: %@", ce.localizedDescription];
        }
        BOOL back = NO;
        if (!err) {
            status(@"Waiting for the board to restart…");
            for (int i = 0; i < 60 && !back; i++) {
                usleep(500000);
                if ([fm fileExistsAtPath:vol]) continue;
                for (NSString *n in [fm contentsOfDirectoryAtPath:@"/dev" error:nil]) if ([n hasPrefix:@"cu.usbmodem"]) back = YES;
            }
            if (!back) err = @"The firmware was copied, but the board did not come back on USB within 30 seconds. Replug it.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            wSelf.statusLabel.stringValue = err ? @"Firmware update failed." : @"Board firmware updated.";
            [wSelf.samplerLink logLine:err ? [@"Firmware update failed: " stringByAppendingString:err] : @"Firmware updated; the board is back on USB."];
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = err ? @"Firmware update failed" : @"Firmware updated";
            a.informativeText = err ?: @"The board is back on USB. Rescan or re-open the disk on the sampler.";
            [a runModal];
        });
    });
}

- (NSURL *)imageFolderURL { return [self _imagesFolder]; }
- (void)chooseImageFolder:(id)sender { [self _chooseImagesFolder:sender]; }

// Settings > Image folder
- (void)_chooseImagesFolder:(id)sender {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseDirectories = YES; op.canChooseFiles = NO; op.canCreateDirectories = YES;
    op.directoryURL = [self _imagesFolder];
    op.message = @"Choose the folder for your EMU3 images (a disk or a NAS share works). The auto-mount agent mounts every .hda/.iso in it as a volume under ~/EMU3 Disks, and New Image saves there by default.";
    op.prompt = @"Use This Folder";
    if ([op runModal] != NSModalResponseOK) return;
    NSString *path = op.URL.path;
    NSString *dir = [[self _watchFilePath] stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *e = nil;
    if (![[path stringByAppendingString:@"\n"] writeToFile:[self _watchFilePath] atomically:YES encoding:NSUTF8StringEncoding error:&e]) {
        [[NSAlert alertWithError:e] runModal]; return;
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Image folder set";
    a.informativeText = [NSString stringWithFormat:@"%@\n\nImages in it are mounted by the auto-mount agent within about 10 seconds (volumes appear under ~/EMU3 Disks). New Image saves there by default.", path];
    [a runModal];
}

- (double)_newImageUnitBytes {
    return self.niUnit.indexOfSelectedItem == 0 ? 1048576.0 : 1073741824.0;   // MB / GB (binary, like the sampler shows)
}

- (void)_newImagePanelChanged:(id)sender {
    if (sender == self.niVolume && self.niVolume.indexOfSelectedItem == (NSInteger)self.niVolumes.count) {
        // "Other folder…"
        NSOpenPanel *op = [NSOpenPanel openPanel];
        op.canChooseDirectories = YES; op.canChooseFiles = NO; op.prompt = @"Choose";
        if ([op runModal] == NSModalResponseOK) {
            NSMutableArray *vs = [self.niVolumes mutableCopy];
            NSURL *u = op.URL;
            NSDictionary *vals = [u resourceValuesForKeys:@[NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityKey,
                                                            NSURLVolumeLocalizedFormatDescriptionKey] error:nil];
            [vs addObject:@{ @"url": u, @"name": u.lastPathComponent, @"format": vals[NSURLVolumeLocalizedFormatDescriptionKey] ?: @"?",
                             @"fat32": @NO, @"total": vals[NSURLVolumeTotalCapacityKey] ?: @0,
                             @"free": vals[NSURLVolumeAvailableCapacityKey] ?: @0, @"external": @NO }];
            self.niVolumes = vs;
            [self.niVolume insertItemWithTitle:[@"Folder: " stringByAppendingString:u.lastPathComponent] atIndex:self.niVolumes.count - 1];
            [self.niVolume selectItemAtIndex:self.niVolumes.count - 1];
        } else {
            [self.niVolume selectItemAtIndex:0];
        }
    }
    NSDictionary *v = [self _selectedNewImageVolume];
    NSString *info = v ? [self _describeVolume:v] : @"";
    double gb = self.niSize.doubleValue;
    if (v && gb > 0) {
        unsigned long long need = (unsigned long long)(gb * [self _newImageUnitBytes]);
        unsigned long long free = [v[@"free"] unsignedLongLongValue];
        info = [info stringByAppendingFormat:@"\nNew image: %@ with an EMU3 (EOS) file system, %@ the free space.", EMU3SizeString(need),
                need <= free ? @"fits in" : @"LARGER than"];
    }
    self.niInfo.stringValue = info;
    // Keep the file name field in step with SCSI ID and size, unless the user typed their own name.
    NSString *autoName = [self _newImageAutoName];
    NSString *cur = self.niName.stringValue;
    if (cur.length == 0 || [cur isEqualToString:self.niAutoName]) self.niName.stringValue = autoName;
    self.niAutoName = autoName;
}

- (NSString *)_newImageAutoName {
    NSString *sizeTag = [NSString stringWithFormat:@"%g%@", self.niSize.doubleValue, self.niUnit.titleOfSelectedItem];   // 14GB, 512MB
    return [NSString stringWithFormat:@"HD%ld0_%@.hda", (long)self.niScsi.indexOfSelectedItem, sizeTag];
}

// Tools > New Image…
- (void)_newImage:(id)sender {
    NSArray *vols = [self _mountedVolumeInfos];
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *v in vols) if ([v[@"external"] boolValue]) [list addObject:v];
    for (NSDictionary *v in vols) if (![v[@"external"] boolValue]) [list addObject:v];
    // Default destination: ~/EMU3 Images (the folder the login auto-mount agent watches).
    NSURL *imagesDir = [self _imagesFolder];
    [NSFileManager.defaultManager createDirectoryAtURL:imagesDir withIntermediateDirectories:YES attributes:nil error:nil];
    {
        NSDictionary *vals = [imagesDir resourceValuesForKeys:@[NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityKey,
                                                                NSURLVolumeLocalizedFormatDescriptionKey] error:nil];
        [list insertObject:@{ @"url": imagesDir, @"name": imagesDir.lastPathComponent, @"format": vals[NSURLVolumeLocalizedFormatDescriptionKey] ?: @"?",
                              @"fat32": @NO, @"total": vals[NSURLVolumeTotalCapacityKey] ?: @0,
                              @"free": vals[NSURLVolumeAvailableCapacityKey] ?: @0, @"external": @NO, @"isImagesFolder": @YES } atIndex:0];
    }
    self.niVolumes = list;

    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 232)];
    NSTextField *l1 = [NSTextField labelWithString:@"Create on:"]; l1.frame = NSMakeRect(0, 208, 90, 17);
    self.niVolume = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(95, 204, 305, 26)];
    for (NSDictionary *v in list)
        [self.niVolume addItemWithTitle:[v[@"isImagesFolder"] boolValue] ? [@"Folder: " stringByAppendingString:[self _imagesFolder].path.stringByAbbreviatingWithTildeInPath] :
                                        [NSString stringWithFormat:@"%@%@ (%@)", [v[@"external"] boolValue] ? @"" : @"Disk: ", v[@"name"], EMU3SizeString([v[@"total"] unsignedLongLongValue])]];
    [self.niVolume addItemWithTitle:@"Other folder…"];
    self.niVolume.target = self; self.niVolume.action = @selector(_newImagePanelChanged:);

    NSTextField *l2 = [NSTextField labelWithString:@"Size:"]; l2.frame = NSMakeRect(0, 172, 90, 17);
    self.niSize = [NSTextField textFieldWithString:@"14"]; self.niSize.frame = NSMakeRect(95, 168, 70, 24);
    self.niSize.target = self; self.niSize.action = @selector(_newImagePanelChanged:);
    self.niUnit = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(168, 166, 62, 26)];
    [self.niUnit addItemsWithTitles:@[@"MB", @"GB"]]; [self.niUnit selectItemAtIndex:1];
    self.niUnit.target = self; self.niUnit.action = @selector(_newImagePanelChanged:);
    NSPopUpButton *presets = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(238, 166, 110, 26) pullsDown:YES];
    [presets addItemWithTitle:@"Presets"];
    // Powers of two from 8 MB to 512 GB (512 GB is the largest disk the E6400 / EOS 4.62 addresses), plus 14 GB.
    for (NSString *g in @[@"8 MB", @"16 MB", @"32 MB", @"64 MB", @"128 MB", @"256 MB", @"512 MB", @"1 GB", @"2 GB", @"4 GB",
                          @"8 GB", @"14 GB", @"16 GB", @"32 GB", @"64 GB", @"128 GB", @"256 GB", @"512 GB"])
        [presets addItemWithTitle:g];
    presets.target = self; presets.action = @selector(_newImagePreset:);

    NSTextField *l3 = [NSTextField labelWithString:@"SCSI ID:"]; l3.frame = NSMakeRect(0, 136, 90, 17);
    self.niScsi = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(95, 132, 70, 26)];
    for (int i = 0; i <= 6; i++) [self.niScsi addItemWithTitle:[NSString stringWithFormat:@"%d", i]];
    [self.niScsi selectItemAtIndex:2];
    NSTextField *l4 = [NSTextField labelWithString:@"Name:"]; l4.frame = NSMakeRect(180, 136, 45, 17);
    self.niName = [NSTextField textFieldWithString:@""]; self.niName.frame = NSMakeRect(228, 132, 172, 24);
    self.niName.placeholderString = @"HD20_14GB.hda";
    self.niScsi.target = self; self.niScsi.action = @selector(_newImagePanelChanged:);
    self.niAutoName = nil;

    self.niFormat = [NSButton checkboxWithTitle:@"Format as an empty EOS disk after creating" target:nil action:nil];
    self.niFormat.state = NSControlStateValueOn; self.niFormat.frame = NSMakeRect(0, 104, 400, 20);

    self.niInfo = [NSTextField wrappingLabelWithString:@""];
    self.niInfo.frame = NSMakeRect(0, 0, 400, 96);
    self.niInfo.font = [NSFont systemFontOfSize:11]; self.niInfo.textColor = NSColor.secondaryLabelColor;
    for (NSView *v in @[l1, self.niVolume, l2, self.niSize, self.niUnit, presets, l3, self.niScsi, l4, self.niName, self.niFormat, self.niInfo]) [acc addSubview:v];
    self.niName.stringValue = @"";
    [self _newImagePanelChanged:nil];

    while (YES) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Create a new disk image";
        a.informativeText = @"BlueSCSI takes the SCSI ID from the name: HD<ID>0_… (e.g. HD20_14GB.hda is SCSI ID 2).";
        a.accessoryView = acc;
        [a addButtonWithTitle:@"Create"];
        [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] != NSAlertFirstButtonReturn) return;

        NSDictionary *v = [self _selectedNewImageVolume];
        double gb = self.niSize.doubleValue;
        NSString *problem = nil;
        if (!v) problem = @"Choose where to create the image.";
        unsigned long long bytes = (unsigned long long)(gb * [self _newImageUnitBytes]) / 512 * 512;
        if (!problem && (bytes < 8ULL << 20 || bytes > 512ULL << 30)) problem = @"Choose a size between 8 MB and 512 GB (the sampler cannot address more).";
        if (!problem && [v[@"fat32"] boolValue] && bytes >= 4ULL * 1000 * 1000 * 1000)
            problem = [NSString stringWithFormat:@"%@ is formatted as FAT32, which cannot hold a file of %@. Erase the card as exFAT, or choose less than 4 GB.", v[@"name"], EMU3SizeString(bytes)];
        if (!problem && bytes > 64ULL * 1024 * 1024 && EMU3IsBoardUSBVolume(v[@"url"]))
            problem = @"This card is connected through the BlueSCSI's USB port (about 1 MB/s). Creating an image there would take hours. Eject the card, take it out of the BlueSCSI and use a card reader on the Mac.";

        if (problem) {
            NSAlert *p = [[NSAlert alloc] init]; p.alertStyle = NSAlertStyleWarning;
            p.messageText = @"Cannot create this image"; p.informativeText = problem;
            [p runModal]; continue;
        }
        if (bytes > [v[@"free"] unsignedLongLongValue]) {
            NSAlert *p = [[NSAlert alloc] init]; p.alertStyle = NSAlertStyleWarning;
            p.messageText = @"Create a sparse image?";
            p.informativeText = [NSString stringWithFormat:@"The image is %@ but only %@ is free on %@. It will be created as a sparse file that only takes space as data is written. The sampler or the app fails with a write error once the volume is full.",
                                 EMU3SizeString(bytes), EMU3SizeString([v[@"free"] unsignedLongLongValue]), v[@"name"]];
            [p addButtonWithTitle:@"Create Sparse Image"]; [p addButtonWithTitle:@"Cancel"];
            if ([p runModal] != NSAlertFirstButtonReturn) continue;
        }

        NSString *fname = [self.niName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        fname = [fname stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
        if (fname.length == 0) fname = [self _newImageAutoName];
        if (![fname.pathExtension.lowercaseString isEqualToString:@"hda"] && ![fname.pathExtension.lowercaseString isEqualToString:@"iso"])
            fname = [fname stringByAppendingString:@".hda"];
        NSURL *dest = [(NSURL *)v[@"url"] URLByAppendingPathComponent:fname];
        if ([NSFileManager.defaultManager fileExistsAtPath:dest.path]) {
            NSAlert *p = [[NSAlert alloc] init]; p.alertStyle = NSAlertStyleWarning;
            p.messageText = @"A file with this name already exists";
            p.informativeText = [NSString stringWithFormat:@"%@ is already on %@. Choose another name.", fname, v[@"name"]];
            [p runModal]; continue;
        }
        [self _createImageAtURL:dest bytes:bytes format:self.niFormat.state == NSControlStateValueOn];
        return;
    }
}

- (void)_newImagePreset:(NSPopUpButton *)sender {
    NSString *t = sender.titleOfSelectedItem;
    NSArray *parts = [t componentsSeparatedByString:@" "];
    if (parts.count == 2) {
        self.niSize.stringValue = parts[0];
        [self.niUnit selectItemAtIndex:[parts[1] isEqualToString:@"MB"] ? 0 : 1];
    }
    [self _newImagePanelChanged:nil];
}

- (void)_createImageAtURL:(NSURL *)dest bytes:(unsigned long long)bytes format:(BOOL)doFormat {
    [self _showProgressTitle:[NSString stringWithFormat:@"Creating %@", dest.lastPathComponent]
                      detail:[NSString stringWithFormat:@"%@ on %@. Large images on SD cards can take a few minutes.", EMU3SizeString(bytes), dest.URLByDeletingLastPathComponent.lastPathComponent]
                       total:1];
    self.progressBar.indeterminate = YES; [self.progressBar startAnimation:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        int fd = open(dest.fileSystemRepresentation, O_RDWR | O_CREAT | O_EXCL, 0644);
        if (fd < 0) err = [NSString stringWithFormat:@"Cannot create the file: %s", strerror(errno)];
        else {
            if (ftruncate(fd, (off_t)bytes) != 0) err = [NSString stringWithFormat:@"Cannot size the file: %s", strerror(errno)];
            close(fd);
        }
        if (!err && doFormat) {
            NSError *e = nil;
            EMU3Filesystem *fs = [[EMU3Filesystem alloc] initWithURL:dest error:&e];
            // A blank file has no EMU3 signature, so write one before opening is not needed:
            // open fails for unformatted files, so fall back to a minimal stub first.
            if (!fs) {
                int f2 = open(dest.fileSystemRepresentation, O_RDWR);
                if (f2 >= 0) { pwrite(f2, "EMU3", 4, 0); close(f2); }
                fs = [[EMU3Filesystem alloc] initWithURL:dest error:&e];
            }
            if (!fs || ![fs formatWithError:&e]) err = [NSString stringWithFormat:@"Created, but formatting failed: %@", e.localizedDescription ?: @"unknown error"];
            else [fs synchronizeToDisk:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _hideProgress];
            if (err) {
                if ([err hasPrefix:@"Cannot"]) unlink(dest.fileSystemRepresentation);
                NSAlert *a = [[NSAlert alloc] init]; a.alertStyle = NSAlertStyleWarning;
                a.messageText = @"Image creation failed"; a.informativeText = err;
                [a beginSheetModalForWindow:self.window completionHandler:nil];
                return;
            }
            self.statusLabel.stringValue = [NSString stringWithFormat:@"Created %@ (%@).", dest.lastPathComponent, EMU3SizeString(bytes)];
            [self openImageAtURL:dest];
        });
    });
}


#pragma mark - Tools: SD card formatter

static NSDictionary *EMU3RunTool(NSString *path, NSArray<NSString *> *args, int *status) {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args;
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p; t.standardError = p;
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) { if (status) *status = -1; return @{@"out": e.localizedDescription ?: @""}; }
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    if (status) *status = t.terminationStatus;
    return @{@"data": d ?: [NSData data], @"out": [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @""};
}

static NSDictionary *EMU3DiskInfo(NSString *target) {
    int st = 0;
    NSDictionary *r = EMU3RunTool(@"/usr/sbin/diskutil", @[@"info", @"-plist", target], &st);
    if (st != 0 || ![r[@"data"] length]) return nil;
    return [NSPropertyListSerialization propertyListWithData:r[@"data"] options:0 format:NULL error:nil];
}

// Physical, non-internal disks with a mounted volume that are small enough to be an SD card.
- (NSArray<NSDictionary *> *)_candidateSDCards {
    NSMutableDictionary<NSString *, NSDictionary *> *byDisk = [NSMutableDictionary dictionary];
    for (NSDictionary *v in [self _mountedVolumeInfos]) {
        NSDictionary *vi = EMU3DiskInfo([(NSURL *)v[@"url"] path]);
        NSString *whole = vi[@"ParentWholeDisk"];
        if (!whole || byDisk[whole]) continue;
        NSDictionary *di = EMU3DiskInfo([@"/dev/" stringByAppendingString:whole]);
        if (!di || [di[@"Internal"] boolValue] || [di[@"VirtualOrPhysical"] isEqualToString:@"Virtual"]) continue;
        unsigned long long size = [di[@"TotalSize"] unsignedLongLongValue];
        if (size == 0 || size > 256ULL * 1000 * 1000 * 1000) continue;   // never offer big disks
        byDisk[whole] = @{ @"disk": whole,
                           @"size": @(size),
                           @"media": di[@"MediaName"] ?: @"Disk",
                           @"volume": v[@"name"] ?: @"",
                           @"volumeURL": v[@"url"] };
    }
    return [byDisk.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"disk"] compare:b[@"disk"]];
    }];
}

// Tools > Format SD Card…
- (void)_formatSDCard:(id)sender {
    NSArray<NSDictionary *> *cards = [self _candidateSDCards];
    if (cards.count == 0) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"No SD card found";
        a.informativeText = @"Insert an SD card or card reader. Only external disks of 256 GB or less are offered, and the card must show up on the desktop (a mounted volume).";
        [a beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 120)];
    NSTextField *l1 = [NSTextField labelWithString:@"Card:"]; l1.frame = NSMakeRect(0, 94, 70, 17);
    NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(75, 90, 325, 26)];
    for (NSDictionary *c in cards)
        [pop addItemWithTitle:[NSString stringWithFormat:@"%@ – %@ (%@, %@)", c[@"volume"], EMU3SizeString([c[@"size"] unsignedLongLongValue]), c[@"media"], c[@"disk"]]];
    NSTextField *l2 = [NSTextField labelWithString:@"Format:"]; l2.frame = NSMakeRect(0, 58, 70, 17);
    NSPopUpButton *fmt = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(75, 54, 325, 26)];
    [fmt addItemWithTitle:@"exFAT (recommended: images of 4 GB and more)"];
    [fmt addItemWithTitle:@"FAT32 (images below 4 GB only)"];
    NSTextField *l3 = [NSTextField labelWithString:@"Name:"]; l3.frame = NSMakeRect(0, 24, 70, 17);
    NSTextField *nameField = [NSTextField textFieldWithString:@"BLUESCSI"]; nameField.frame = NSMakeRect(75, 20, 200, 24);
    NSTextField *note = [NSTextField labelWithString:@"MBR partition scheme, as BlueSCSI expects."];
    note.font = [NSFont systemFontOfSize:11]; note.textColor = NSColor.secondaryLabelColor; note.frame = NSMakeRect(0, 0, 400, 14);
    for (NSView *v in @[l1, pop, l2, fmt, l3, nameField, note]) [acc addSubview:v];

    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Format an SD card";
    a.informativeText = @"Erases EVERYTHING on the chosen card, including any BlueSCSI images and settings.";
    a.accessoryView = acc;
    [a addButtonWithTitle:@"Continue…"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;

    NSDictionary *card = cards[MAX(0, pop.indexOfSelectedItem)];
    BOOL exfat = fmt.indexOfSelectedItem == 0;
    NSMutableString *vname = [NSMutableString string];
    for (NSUInteger i = 0; i < nameField.stringValue.length; i++) {
        unichar c = [nameField.stringValue.uppercaseString characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') [vname appendFormat:@"%C", c];
    }
    if (vname.length == 0) [vname setString:@"BLUESCSI"];
    if (vname.length > (exfat ? 15 : 11)) [vname setString:[vname substringToIndex:exfat ? 15 : 11]];

    // Images that live on this card must not be open while it is erased.
    NSString *mountPath = [(NSURL *)card[@"volumeURL"] path];
    for (EMU3Filesystem *fs in self.mountedImagesCtl.filesystems) {
        if ([fs.imageURL.path hasPrefix:[mountPath stringByAppendingString:@"/"]]) {
            NSAlert *w = [[NSAlert alloc] init]; w.alertStyle = NSAlertStyleWarning;
            w.messageText = @"An image on this card is open";
            w.informativeText = [NSString stringWithFormat:@"Unmount %@ first (right-click it in the tree), then format the card.", fs.imageURL.lastPathComponent];
            [w beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }
    }

    NSAlert *c = [[NSAlert alloc] init];
    c.alertStyle = NSAlertStyleCritical;
    c.messageText = [NSString stringWithFormat:@"Erase \"%@\" (%@, %@)?", card[@"volume"], EMU3SizeString([card[@"size"] unsignedLongLongValue]), card[@"disk"]];
    c.informativeText = [NSString stringWithFormat:@"All data on the card will be destroyed and the card formatted as %@ named %@. This cannot be undone.\n\nCheck that this is the SD card and not another drive.", exfat ? @"exFAT" : @"FAT32", vname];
    [c addButtonWithTitle:@"Cancel"];
    [c addButtonWithTitle:@"Erase and Format"];
    c.buttons.lastObject.hasDestructiveAction = YES;
    if ([c runModal] != NSAlertSecondButtonReturn) return;

    NSString *disk = card[@"disk"];
    [self _showProgressTitle:[NSString stringWithFormat:@"Formatting %@", card[@"volume"]]
                      detail:@"Erasing and formatting the card…" total:1];
    self.progressBar.indeterminate = YES; [self.progressBar startAnimation:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int st = 0;
        NSDictionary *r = EMU3RunTool(@"/usr/sbin/diskutil",
            @[@"eraseDisk", exfat ? @"ExFAT" : @"MS-DOS FAT32", vname, @"MBR", [@"/dev/" stringByAppendingString:disk]], &st);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _hideProgress];
            if (st == 0) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Formatted the card as %@ \"%@\".", exfat ? @"exFAT" : @"FAT32", vname];
                NSAlert *ok = [[NSAlert alloc] init];
                ok.messageText = @"Card formatted";
                ok.informativeText = [NSString stringWithFormat:@"%@ is ready. Use Tools > New Image… to put a disk image on it.", vname];
                [ok beginSheetModalForWindow:self.window completionHandler:nil];
            } else {
                self.statusLabel.stringValue = @"Formatting the card failed.";
                NSAlert *bad = [[NSAlert alloc] init]; bad.alertStyle = NSAlertStyleWarning;
                bad.messageText = @"Formatting failed";
                bad.informativeText = [r[@"out"] length] ? r[@"out"] : @"diskutil reported an error.";
                [bad beginSheetModalForWindow:self.window completionHandler:nil];
            }
        });
    });
}


// Tools > Unmount & Eject Card…
- (void)_ejectCard:(id)sender {
    NSMutableArray<NSDictionary *> *cards = [NSMutableArray array];
    for (NSDictionary *c in [self _candidateSDCards]) [cards addObject:c];
    if (cards.count == 0) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"No SD card found";
        a.informativeText = @"There is no external card to eject.";
        [a beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 340, 26)];
    for (NSDictionary *c in cards)
        [pop addItemWithTitle:[NSString stringWithFormat:@"%@ – %@ (%@)", c[@"volume"], EMU3SizeString([c[@"size"] unsignedLongLongValue]), c[@"disk"]]];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Unmount and eject a card";
    a.informativeText = @"Images from the card that are open in the app are closed and saved first.";
    a.accessoryView = pop;
    [a addButtonWithTitle:@"Eject"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;

    NSDictionary *card = cards[MAX(0, pop.indexOfSelectedItem)];
    NSString *prefix = [[(NSURL *)card[@"volumeURL"] path] stringByAppendingString:@"/"];
    NSMutableArray<EMU3Filesystem *> *onCard = [NSMutableArray array];
    for (EMU3Filesystem *fs in self.mountedImagesCtl.filesystems)
        if ([fs.imageURL.path hasPrefix:prefix]) [onCard addObject:fs];
    if (onCard.count) [self _unmountFilesystems:onCard];

    NSString *disk = card[@"disk"], *volName = card[@"volume"];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Ejecting %@…", volName];
    [self _showProgressTitle:[NSString stringWithFormat:@"Ejecting %@", volName] detail:@"Saving images and unmounting…" total:1];
    self.progressBar.indeterminate = YES; [self.progressBar startAnimation:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (EMU3Filesystem *fs in onCard) [fs closeImage];     // flush and release the files
        sync();
        int st = 0; NSDictionary *r = nil;
        for (int attempt = 0; attempt < 3; attempt++) {
            r = EMU3RunTool(@"/usr/sbin/diskutil", @[@"eject", [@"/dev/" stringByAppendingString:disk]], &st);
            if (st == 0) break;
            [NSThread sleepForTimeInterval:1.0];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _hideProgress];
            if (st == 0) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"%@ ejected. It is safe to remove the card.", volName];
            } else {
                self.statusLabel.stringValue = @"Eject failed.";
                NSAlert *bad = [[NSAlert alloc] init]; bad.alertStyle = NSAlertStyleWarning;
                bad.messageText = @"Could not eject the card";
                bad.informativeText = [r[@"out"] length] ? r[@"out"] : @"Another program is probably using the card.";
                [bad beginSheetModalForWindow:self.window completionHandler:nil];
            }
        });
    });
}


// Tools > Sampler Mode (Lock Images): the sampler and the Mac must never write to the same image
// at the same time. The BlueSCSI cannot tell the Mac whether the sampler is on, so this is a switch:
// ON = every open image is locked read-only, OFF = images can be edited.
- (void)_toggleSamplerMode:(id)sender {
    [self _setSamplerMode:!self.samplerMode];
}

// Tools ▸ Sampler Link…: serve an image to the BlueSCSI board over USB.
// Tools ▸ Mount Image as Volume: shows the open image as a real disk in Finder.
- (void)_mountImageAsVolume:(id)sender {
    EMU3Filesystem *fs = [self _mountedFilesystemForClickedOrSelectedRow];
    NSAlert *a = [[NSAlert alloc] init];
    if (!fs) { NSBeep(); return; }
    if (!self.volumeMounts) self.volumeMounts = [NSMutableDictionary dictionary];
    EMU3VolumeMount *existing = self.volumeMounts[fs.imageURL.path];
    if (existing) { [NSWorkspace.sharedWorkspace openURL:existing.mountPoint]; return; }
    NSString *why = [EMU3VolumeMount unavailableReason];
    if (!why && self.samplerMode) why = @"Sampler Mode is on and locks all images. Turn it off first (Tools ▸ Sampler Mode).";
    if (why) {
        a.messageText = @"Cannot mount the image";
        a.informativeText = why;
        [a runModal];
        return;
    }
    EMU3VolumeMount *m = [[EMU3VolumeMount alloc] initWithFilesystem:fs];
    __weak typeof(self) weak = self;
    NSString *key = fs.imageURL.path;
    m.serverForImage = ^EMU3BlockServer *(NSURL *u) {
        EMU3BlockServer *s = weak.samplerLink.activeServer;
        return (s && [s.imageURL.path isEqualToString:u.path]) ? s : nil;
    };
    m.imageChangedThroughMount = ^(EMU3VolumeMount *mm) {
        [weak _samplerChangedImage:mm.filesystem.imageURL];
        [weak.samplerLink noteImageEditedByApp];
    };
    m.didStop = ^(EMU3VolumeMount *mm) {
        [weak.volumeMounts removeObjectForKey:key];
        weak.statusLabel.stringValue = [NSString stringWithFormat:@"%@ is no longer mounted as a volume.", mm.filesystem.imageURL.lastPathComponent];
    };
    self.volumeMounts[key] = m;
    self.statusLabel.stringValue = @"Mounting…";
    [m mountWithCompletion:^(NSError *error) {
        if (error) {
            [weak.volumeMounts removeObjectForKey:key];
            NSAlert *ea = [[NSAlert alloc] init];
            ea.messageText = @"Could not mount the image";
            ea.informativeText = error.localizedDescription;
            [ea runModal];
            return;
        }
        weak.statusLabel.stringValue = [NSString stringWithFormat:@"Mounted at %@", m.mountPoint.path];
        [NSWorkspace.sharedWorkspace openURL:m.mountPoint];
    }];
}

- (void)_unmountImageVolume:(id)sender {
    EMU3Filesystem *fs = [self _mountedFilesystemForClickedOrSelectedRow];
    EMU3VolumeMount *m = fs ? self.volumeMounts[fs.imageURL.path] : nil;
    if (!m) { NSBeep(); return; }
    [m unmount];
}

- (void)unmountAllVolumes {
    for (EMU3VolumeMount *m in [self.volumeMounts.allValues copy]) [m unmount];
}

- (void)_showSamplerLink:(id)sender {
    [self _ensureSamplerLink];
    [self.samplerLink showAndRefresh];
}

// Creates the Sampler Link controller (also at launch, so a disk the helper already serves is guarded and shown).
- (void)_ensureSamplerLink {
    if (!self.samplerLink) {
        EMU3SamplerLinkController *c = [[EMU3SamplerLinkController alloc] init];
        __weak typeof(self) weak = self;
        c.mountedImageURLs = ^NSArray<NSURL *> *{
            NSMutableArray *a = [NSMutableArray array];
            for (EMU3Filesystem *fs in weak.mountedFilesystems) [a addObject:fs.imageURL];
            return a;
        };
        c.openImage = ^(NSURL *url) {
            for (EMU3Filesystem *fs in weak.mountedFilesystems) if ([fs.imageURL.path isEqualToString:url.path]) return;
            [weak openImageAtURL:url];
        };
        c.imageChangedBySampler = ^(NSURL *url) { [weak _samplerChangedImage:url]; };
        c.servingChanged = ^(EMU3BlockServer *srv) { [weak _updateEditGates]; };
        self.samplerLink = c;
        [c attachIfServed];
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { [weak _refreshServedMarker]; }];
    }
}

// While an image is served to the sampler, every edit made here waits until the sampler is idle and
// holds the server for its duration (see EMU3BlockServer acquireForEdit…). Other images are unguarded.
// Keeps the sampler strip (top of the left pane) in step with the link: image name, status dot and state.
// The served image is shown only there; it is taken out of the mount list below.
- (void)_refreshServedMarker {
    EMU3BlockServer *srv = self.samplerLink.activeServer;
    EMU3Filesystem *servedFS = nil;
    // The strip keeps the last served image in place when serving stops (or after a restart), shown as "Not served".
    NSString *stripPath = srv.imageURL.path;
    if (stripPath) [NSUserDefaults.standardUserDefaults setObject:stripPath forKey:@"EMU3LastServedImage"];
    else stripPath = [NSUserDefaults.standardUserDefaults stringForKey:@"EMU3LastServedImage"];
    if (stripPath) for (EMU3Filesystem *fs in self.mountedFilesystems) if ([fs.imageURL.path isEqualToString:stripPath]) servedFS = fs;
    // The state text is centered in the strip; the name takes all the room to its left, so it never truncates needlessly.
    CGFloat sw = NSWidth(self.servedStrip.bounds);
    self.servedStateLabel.autoresizingMask = NSViewNotSizable;
    self.servedStateLabel.frame = NSMakeRect(sw / 2 - 70, 6, 140, 14);
    self.servedNameLabel.frame = NSMakeRect(24, 6, MAX(88, sw / 2 - 75 - 24), 16);
    MountedImagesController *m = self.mountedImagesCtl;
    if (m && m.hiddenFilesystem != servedFS) {
        EMU3Filesystem *old = m.hiddenFilesystem;
        m.hiddenFilesystem = servedFS;
        [m reloadData];
        if (old && !servedFS && old == self.filesystem) [m selectFilesystem:old directory:self.currentDirectory];   // back into the list
        if (servedFS && servedFS == self.filesystem) [m selectFilesystem:servedFS directory:nil];                  // out of the list
    }
    self.servedStrip.selected = servedFS && servedFS == self.filesystem;
    if (!srv) {
        self.servedNameLabel.stringValue = servedFS ? [servedFS.imageURL.lastPathComponent stringByDeletingPathExtension] : @"Nothing served";
        self.servedNameLabel.toolTip = servedFS && EMU3TooltipsEnabled() ? servedFS.imageURL.path : nil;
        self.servedNameLabel.textColor = NSColor.secondaryLabelColor;
        self.servedStateLabel.stringValue = servedFS ? @"Server is not running" : @"";
        self.servedDot.contentTintColor = NSColor.systemGrayColor;
        return;
    }
    NSColor *c = NSColor.systemGrayColor; NSString *state = @"";
    switch (srv.state) {
        case EMU3LinkStateWaitingForBoard: c = NSColor.systemOrangeColor; state = @"Waiting for the board"; break;
        case EMU3LinkStateBoardConnected:  c = NSColor.systemYellowColor; state = @"Board connected"; break;
        case EMU3LinkStateActive:          c = NSColor.systemGreenColor;  state = @"Sampler active"; break;
        default: break;
    }
    self.servedNameLabel.stringValue = [srv.imageURL.lastPathComponent stringByDeletingPathExtension] ?: @"";
    self.servedNameLabel.toolTip = EMU3TooltipsEnabled() ? srv.imageURL.path : nil;
    self.servedNameLabel.textColor = NSColor.labelColor;
    self.servedStateLabel.stringValue = state;
    self.servedDot.contentTintColor = c;
}

// Click on the strip: show the served image in the right pane. Double-click: open the Sampler Link window.
- (void)_servedStripClicked:(NSGestureRecognizer *)g {
    EMU3Filesystem *fs = self.mountedImagesCtl.hiddenFilesystem;
    if (!fs) return;
    [self.mountedImagesCtl selectFilesystem:fs directory:nil];
    if (self.mountedImagesCtl.selectionChanged) self.mountedImagesCtl.selectionChanged(fs, nil);
}

// Whole images or Finder files dropped on the strip go into the served image.
- (BOOL)_dropOnServedStrip:(NSPasteboard *)pb {
    EMU3Filesystem *fs = self.mountedImagesCtl.hiddenFilesystem;
    if (!fs || fs.isReadOnly) { NSBeep(); return NO; }
    NSArray<NSURL *(^)(void)> *exps = EMU3ImageDragExporters(pb);
    if (exps) {
        if (!EMU3ConfirmImageDrop(pb, fs)) return YES;
        self.statusLabel.stringValue = @"Reading the dragged images…";
        __weak typeof(self) wSelf = self;
        EMU3ExportDraggedImages(exps, ^(NSArray<NSURL *> *folders) {
            if (!folders.count) { wSelf.statusLabel.stringValue = @"Could not read the image."; return; }
            [wSelf _handleTreeDropOnFilesystem:fs directory:nil urls:folders isInternal:NO move:NO];
        });
        return YES;
    }
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) return NO;
    [self _handleTreeDropOnFilesystem:fs directory:nil urls:urls isInternal:NO move:NO];
    return YES;
}

- (void)_servedStripDoubleClicked:(NSGestureRecognizer *)g { [self _showSamplerLink:nil]; }

- (void)_updateEditGates {
    [self _refreshServedMarker];
    EMU3BlockServer *srv = self.samplerLink.activeServer;
    NSString *served = srv ? srv.imageURL.path : nil;
    for (EMU3Filesystem *fs in self.mountedFilesystems) {
        if (served && [fs.imageURL.path isEqualToString:served]) {
            __weak typeof(self) weak = self;
            fs.editGateBegin = ^BOOL{ return [srv acquireForEditWithIdle:2.0 timeout:4.0]; };
            fs.editGateEnd = ^{
                [srv releaseEdit];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weak.samplerLink noteImageEditedByApp];
                });
            };
        } else {
            fs.editGateBegin = nil;
            fs.editGateEnd = nil;
        }
    }
}

// The sampler wrote to the image we are serving: re-read the file system and refresh the views.
- (void)_samplerChangedImage:(NSURL *)url {
    for (EMU3Filesystem *fs in [self.mountedFilesystems copy]) {
        if (![fs.imageURL.path isEqualToString:url.path]) continue;
        dispatch_async(fs.ioQueue, ^{
            NSError *e = nil;
            BOOL ok = [fs reload:&e];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) { self.statusLabel.stringValue = [NSString stringWithFormat:@"Could not re-read the image after the sampler changed it: %@", e.localizedDescription]; return; }
                if (fs == self.filesystem) [self _selectImage:fs];
                [self.mountedImagesCtl reloadData];
                [self _updateDiskSpaceLabel];
                self.statusLabel.stringValue = @"The image was changed from outside; view refreshed.";
            });
        });
    }
}

- (void)_setSamplerMode:(BOOL)on {
    self.samplerMode = on;
    for (EMU3Filesystem *fs in self.mountedFilesystems) {
        if (on) [fs synchronizeToDisk:nil];
        fs.locked = on;
    }
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"SamplerMode"];
    [self.mountedImagesCtl reloadData];
    [self _updateDiskSpaceLabel];
    self.window.subtitle = on ? @"Sampler mode: images are locked (read-only)" : @"";
    self.statusLabel.stringValue = on ? @"Sampler mode ON: images are locked, nothing can be changed."
                                      : @"Sampler mode OFF: images can be edited. Make sure the sampler is off or disconnected.";
}


- (void)expandAllInTree:(id)sender { [self.mountedImagesCtl expandAll]; }

- (void)collapseAllInTree:(id)sender { [self.mountedImagesCtl collapseAll]; }

- (void)_unmountImage:(id)sender {
    NSOutlineView *tree = (NSOutlineView *)self.imagesTableView;
    NSMutableArray<EMU3Filesystem *> *targets = [NSMutableArray array];
    NSInteger clicked = tree.clickedRow;
    BOOL clickedInSelection = clicked >= 0 && [tree.selectedRowIndexes containsIndex:(NSUInteger)clicked];
    if (clicked < 0 || clickedInSelection) {
        // Every image row in the (multi-)selection; folder rows count for their image.
        [tree.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            id item = [tree itemAtRow:(NSInteger)idx];
            if ([item isKindOfClass:[EMU3Filesystem class]] && ![targets containsObject:item])
                [targets addObject:item];
        }];
    }
    if (targets.count == 0) {
        // Right-click on an unselected row, or only folders selected: act on that image.
        [self _mountedFilesystemForClickedOrSelectedRow];
        if (self.filesystem) [targets addObject:self.filesystem];
    }
    if (targets.count == 0) return;
    [self _unmountFilesystems:targets];
}

- (void)_unmountFilesystems:(NSArray<EMU3Filesystem *> *)targets {
    BOOL currentGone = NO;
    for (EMU3Filesystem *fs in targets) {
        if (fs == self.filesystem) currentGone = YES;
        [self.mountedFilesystems removeObject:fs];
        [self.mountedImagesCtl removeMountedFilesystem:fs];
    }
    if (!currentGone) { [self _updateMountStatusLabel]; return; }

    self.filesystem = nil;
    self.currentDirectory = nil;
    self.contentCtl.filesystem = nil;
    self.contentCtl.directory = nil;
    [self.contentCtl refresh];
    [self _updateBreadcrumb];

    self.window.title = @"EMU3 Disk Manager";
    self.statusLabel.stringValue = self.mountedFilesystems.count > 0 ? @"Select an image" : @"No image loaded";
    self.diskSpaceLabel.stringValue = @"";
    [self _updateMountStatusLabel];
}

- (EMU3Filesystem *)_mountedFilesystemForClickedOrSelectedRow {
    NSOutlineView *ov = (NSOutlineView *)self.imagesTableView;
    NSInteger row = ov.clickedRow >= 0 ? ov.clickedRow : ov.selectedRow;
    if (row >= 0) {
        EMU3Filesystem *fs = [self.mountedImagesCtl filesystemForItem:[ov itemAtRow:row]];
        if (fs) {
            if (row != ov.selectedRow) {
                [ov selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
            }
            return fs;
        }
    }
    return self.filesystem;
}

- (void)_copyImageAs:(id)sender {
    EMU3Filesystem *fs = [self _mountedFilesystemForClickedOrSelectedRow];
    NSURL *sourceURL = fs.imageURL;
    if (!sourceURL.isFileURL) { NSBeep(); return; }

    NSString *sourceName = sourceURL.lastPathComponent ?: @"DiskImage.hda";
    NSString *baseName = sourceName.stringByDeletingPathExtension;
    NSString *extension = sourceName.pathExtension;
    NSString *copyName = extension.length > 0
        ? [NSString stringWithFormat:@"%@ Copy.%@", baseName, extension]
        : [sourceName stringByAppendingString:@" Copy"];

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Copy Disk Image As";
    panel.message = @"Name the copied disk image.";
    panel.prompt = @"Copy";
    panel.nameFieldStringValue = copyName;
    panel.canCreateDirectories = YES;

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;

        NSURL *destinationURL = panel.URL;
        NSString *sourcePath = sourceURL.path.stringByStandardizingPath;
        NSString *destinationPath = destinationURL.path.stringByStandardizingPath;
        if ([sourcePath isEqualToString:destinationPath]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Choose a different file name";
            alert.informativeText = @"The copy destination cannot be the mounted image itself.";
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }

        // Check the destination volume before copying and let the user decide.
        {
            NSFileManager *cfm = NSFileManager.defaultManager;
            unsigned long long need = [[cfm attributesOfItemAtPath:sourceURL.path error:nil] fileSize];
            unsigned long long existing = [[cfm attributesOfItemAtPath:destinationURL.path error:nil] fileSize];   // replaced by the copy
            NSURL *destDir = destinationURL.URLByDeletingLastPathComponent;
            if (need > 64ULL * 1024 * 1024 && EMU3IsBoardUSBVolume(destDir)) {
                EMU3ShowBoardUSBRefusal(@"Copying a disk image to that card");
                return;
            }
            NSDictionary *vals = [destDir resourceValuesForKeys:@[NSURLVolumeNameKey, NSURLVolumeAvailableCapacityForImportantUsageKey,
                                                                  NSURLVolumeAvailableCapacityKey] error:nil];
            unsigned long long freeB = [vals[NSURLVolumeAvailableCapacityForImportantUsageKey] unsignedLongLongValue];
            if (freeB == 0) freeB = [vals[NSURLVolumeAvailableCapacityKey] unsignedLongLongValue];
            freeB += existing;
            NSString *vol = vals[NSURLVolumeNameKey] ?: destDir.lastPathComponent;
            if (need > freeB) {
                NSAlert *a = [[NSAlert alloc] init];
                a.alertStyle = NSAlertStyleWarning;
                a.messageText = [NSString stringWithFormat:@"Not enough space on \u201c%@\u201d", vol];
                a.informativeText = [NSString stringWithFormat:
                    @"The image \u201c%@\u201d is %@, but only %@ is free on the destination (missing %@).\n\nNothing was copied.",
                    sourceName, EMU3SizeString(need), EMU3SizeString(freeB), EMU3SizeString(need - freeB)];
                [a addButtonWithTitle:@"Choose Another Location\u2026"];
                [a addButtonWithTitle:@"Cancel"];
                if ([a runModal] == NSAlertFirstButtonReturn)
                    dispatch_async(dispatch_get_main_queue(), ^{ [self _copyImageAs:nil]; });
                return;
            }
            NSString *title = [NSString stringWithFormat:@"Copy image to \u201c%@\u201d?", vol];
            NSString *body = [NSString stringWithFormat:@"Image: %@ (%@)\nFree on the destination: %@\nLeft afterwards: %@%@",
                sourceName, EMU3SizeString(need), EMU3SizeString(freeB), EMU3SizeString(freeB - need),
                existing ? @"\n\nAn existing file with this name will be replaced." : @""];
            if (!EMU3RunCenteredConfirm(title, body, @"Copy", @"Cancel")) return;
        }

        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Copying %@...", sourceName];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __block NSError *syncError = nil;
            dispatch_sync(fs.ioQueue, ^{
                [fs synchronizeToDisk:&syncError];
            });

            NSError *copyError = syncError;
            BOOL copied = NO;
            if (!copyError) {
                NSFileManager *fm = NSFileManager.defaultManager;
                if ([fm fileExistsAtPath:destinationURL.path]) {
                    [fm removeItemAtURL:destinationURL error:&copyError];
                }
                if (!copyError) {
                    copied = [fm copyItemAtURL:sourceURL toURL:destinationURL error:&copyError];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                self.spinner.hidden = YES;
                [self.spinner stopAnimation:nil];
                if (copied) {
                    self.statusLabel.stringValue = [NSString stringWithFormat:@"Copied image to %@.", destinationURL.lastPathComponent];
                } else {
                    self.statusLabel.stringValue = @"Copy image failed.";
                    if (copyError) [[NSAlert alertWithError:copyError] beginSheetModalForWindow:self.window completionHandler:nil];
                }
            });
        });
    }];
}

- (NSArray<EMU3File *> *)_selectedFiles {
    NSMutableArray *files = [NSMutableArray array];
    // Get selected items directly from the outline view (tableView is actually an outline view now)
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    [ov.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *s) {
        id item = [ov itemAtRow:idx];
        // Only include files, not directories
        if ([item isKindOfClass:[EMU3File class]]) {
            [files addObject:item];
        }
    }];
    return files;
}

- (NSArray<EMU3Directory *> *)_selectedFolders {
    NSMutableArray *dirs = [NSMutableArray array];
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    [ov.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *s) {
        id item = [ov itemAtRow:idx];
        if ([item isKindOfClass:[EMU3Directory class]]) [dirs addObject:item];
    }];
    return dirs;
}

- (EMU3Directory *)_parentDirectoryForOutlineItem:(id)item {
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    id parent = [ov parentForItem:item];
    while (parent && ![parent isKindOfClass:[EMU3Directory class]]) {
        parent = [ov parentForItem:parent];
    }
    return [parent isKindOfClass:[EMU3Directory class]] ? (EMU3Directory *)parent : self.currentDirectory;
}

- (NSArray<EMU3Directory *> *)_selectedFileDirectories {
    NSMutableArray<EMU3Directory *> *directories = [NSMutableArray array];
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    [ov.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *s) {
        id item = [ov itemAtRow:idx];
        if ([item isKindOfClass:[EMU3File class]]) {
            EMU3Directory *parentDir = [self _parentDirectoryForOutlineItem:item];
            [directories addObject:parentDir ?: self.currentDirectory];
        }
    }];
    return directories;
}

- (NSArray<EMU3SampleItem *> *)_selectedSampleItems {
    NSMutableArray *samples = [NSMutableArray array];
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    [ov.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *s) {
        id item = [ov itemAtRow:idx];
        if ([item isKindOfClass:[EMU3SampleItem class]]) {
            [samples addObject:item];
        }
    }];
    return samples;
}

- (void)_exportSelected:(id)sender {
    NSArray<EMU3File *> *files = [self _selectedFiles];
    if (files.count == 0) { NSBeep(); return; }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.prompt = @"Export Here";
    panel.message = [NSString stringWithFormat:@"Export %lu file(s) to folder", (unsigned long)files.count];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        NSURL *destDir = panel.URL;
        __block NSUInteger failures = 0;
        for (EMU3File *f in files) {
            NSURL *dest = [destDir URLByAppendingPathComponent:
                          [EMU3FileSafeName(f.name) stringByAppendingString:@".E4B"]];
            NSError *err = nil;
            if (![self.filesystem exportFile:f toURL:dest error:&err]) {
                failures++;
                NSLog(@"Export failed for %@: %@", f.name, err);
            }
        }
        NSString *msg = failures == 0
            ? [NSString stringWithFormat:@"Exported %lu file(s) successfully.", (unsigned long)files.count]
            : [NSString stringWithFormat:@"Exported with %lu failure(s).", (unsigned long)failures];
        self.statusLabel.stringValue = msg;
    }];
}

- (void)_exportSamples:(id)sender {
    NSArray<EMU3File *> *files = [self _selectedFiles];
    NSArray<EMU3SampleItem *> *selectedSamples = [self _selectedSampleItems];

    // Filter for bank files only
    NSMutableArray<EMU3File *> *bankFiles = [NSMutableArray array];
    for (EMU3File *f in files) {
        if (f.fileType == EMU3FileTypeBank) {
            [bankFiles addObject:f];
        }
    }

    if (bankFiles.count == 0 && selectedSamples.count == 0) {
        NSBeep();
        return;
    }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.prompt = @"Export Samples";
    panel.message = selectedSamples.count > 0
        ? [NSString stringWithFormat:@"Export %lu selected sample(s)", (unsigned long)selectedSamples.count]
        : [NSString stringWithFormat:@"Export samples from %lu bank(s)", (unsigned long)bankFiles.count];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;

        NSURL *destDir = panel.URL;
        EMU3Filesystem *fs = self.filesystem;

        dispatch_async(fs.ioQueue, ^{
            __block NSUInteger totalSamples = 0;
            __block NSUInteger failures = 0;

            for (EMU3SampleItem *sampleItem in selectedSamples) {
                EMU3File *bankFile = sampleItem.bankFile;
                if (!bankFile) {
                    failures++;
                    continue;
                }

                NSArray<NSString *> *samples = [fs samplesFromBankFile:bankFile error:nil];
                NSString *sampleID = sampleItem.sampleIndex < samples.count
                    ? samples[sampleItem.sampleIndex]
                    : [NSString stringWithFormat:@"Sample_%03lu", (unsigned long)(sampleItem.sampleIndex + 1)];
                NSString *fileName = [NSString stringWithFormat:@"%@_%@.wav", bankFile.name, sampleID];
                NSURL *sampleURL = [destDir URLByAppendingPathComponent:fileName];

                NSError *exportErr = nil;
                if ([fs exportSampleAtIndex:sampleItem.sampleIndex fromBankFile:bankFile toURL:sampleURL error:&exportErr]) {
                    totalSamples++;
                } else {
                    failures++;
                    NSLog(@"Sample export failed for %@[%@]: %@", bankFile.name, sampleID, exportErr);
                }
            }

            if (selectedSamples.count == 0) {
                for (EMU3File *bankFile in bankFiles) {
                    NSError *err = nil;
                    NSArray<NSString *> *samples = [fs samplesFromBankFile:bankFile error:&err];
                    NSUInteger sampleCount = samples.count > 0 ? samples.count : bankFile.sampleCount;

                    for (NSUInteger i = 0; i < sampleCount; i++) {
                        NSString *sampleID = i < samples.count
                            ? samples[i]
                            : [NSString stringWithFormat:@"Sample_%03lu", (unsigned long)(i + 1)];
                        NSString *fileName = [NSString stringWithFormat:@"%@_%@.wav", bankFile.name, sampleID];
                        NSURL *sampleURL = [destDir URLByAppendingPathComponent:fileName];

                        NSError *exportErr = nil;
                        if ([fs exportSampleAtIndex:i fromBankFile:bankFile toURL:sampleURL error:&exportErr]) {
                            totalSamples++;
                        } else {
                            failures++;
                            NSLog(@"Sample export failed for %@[%@]: %@", bankFile.name, sampleID, exportErr);
                        }
                    }
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *msg = failures == 0
                    ? [NSString stringWithFormat:@"Exported %lu sample(s) successfully.", (unsigned long)totalSamples]
                    : [NSString stringWithFormat:@"Exported %lu sample(s) with %lu failure(s).", (unsigned long)totalSamples, (unsigned long)failures];
                self.statusLabel.stringValue = msg;
            });
        });
    }];
}

- (void)_importURLs:(NSArray<NSURL *> *)urls toMountedFilesystem:(EMU3Filesystem *)fs {
    [self _importURLs:urls toMountedFilesystem:fs directory:nil];
}

// Moves (or copies) files dropped on an image or folder in the tree on the left.
- (void)_handleTreeDropOnFilesystem:(EMU3Filesystem *)fs
                          directory:(EMU3Directory *)dir
                               urls:(NSArray<NSURL *> *)urls
                         isInternal:(BOOL)isInternal
                               move:(BOOL)isMove {
    EMU3Directory *dest = dir ?: fs.rootDirectory;
    if (!fs || fs.isReadOnly || !dest) { NSBeep(); return; }

    // Moving files inside the image that is open on the right
    if (isInternal && isMove && fs == self.filesystem) {
        NSArray<EMU3File *> *files = [[self _selectedFiles] copy];
        NSArray<EMU3Directory *> *srcDirs = [[self _selectedFileDirectories] copy];
        BOOL foldersSelected = [(NSOutlineView *)self.tableView selectedRowIndexes].count != files.count;
        if (files.count > 0 && !foldersSelected) {
            self.statusLabel.stringValue = @"Moving…";
            dispatch_async(fs.ioQueue, ^{
                __block NSUInteger ok = 0, fail = 0, skipped = 0;
                for (NSUInteger i = 0; i < files.count; i++) {
                    EMU3Directory *src = i < srcDirs.count ? srcDirs[i] : self.currentDirectory;
                    if (src == dest) { skipped++; continue; }
                    NSError *err = nil;
                    if ([fs moveFile:files[i] fromDirectory:src toDirectory:dest error:&err]) ok++;
                    else { fail++; NSLog(@"Move failed: %@", err); }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.contentCtl refresh];
                    [self _updateDiskSpaceLabel];
                    [self _updateBreadcrumb];
                    NSString *where = dest.name ?: @"folder";
                    NSString *msg = [NSString stringWithFormat:@"Moved %lu file(s) to %@", (unsigned long)ok, where];
                    if (skipped > 0) msg = [msg stringByAppendingFormat:@", %lu already there", (unsigned long)skipped];
                    if (fail > 0)    msg = [msg stringByAppendingFormat:@", %lu failed", (unsigned long)fail];
                    self.statusLabel.stringValue = [msg stringByAppendingString:@"."];
                });
            });
            return;
        }
    }

    // Everything else (other images, Finder files, folders, Option = copy) is imported.
    [self _importURLs:urls toMountedFilesystem:fs directory:dest];
}

// Restores a folder tree from a temp export as ROOT-level folders (EOS has one folder level).
// Sub-folders become their own root folders named "<parent> <child>" (shortened to 15 chars),
// and a folder never gets more than 100 banks. Returns the number of folders created.
- (NSUInteger)_restoreFlatFolderAtURL:(NSURL *)url
                                 name:(NSString *)name
                           filesystem:(EMU3Filesystem *)fs
                     skipOwnNameLevel:(BOOL)skip
                                error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:url
                                includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                   options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    items = [items sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
    NSMutableArray<NSURL *> *files = [NSMutableArray array], *dirs = [NSMutableArray array];
    for (NSURL *u in items) {
        NSNumber *isDir = nil; [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) [dirs addObject:u];
        else if ([u.pathExtension.lowercaseString isEqualToString:@"e4b"]) [files addObject:u];
    }

    NSUInteger created = 0;
    // The image root of a whole-image copy has no name of its own worth keeping when it only
    // contains folders; its folders go straight to the root.
    NSUInteger chunk = 100;
    for (NSUInteger start = 0; start < files.count; start += chunk) {
        NSUInteger len = MIN(chunk, files.count - start);
        NSString *folderName = EMU3UniqueFolderName(EMU3ShortFolderName(name.length ? name : @"Root files"), fs.rootDirectory);
        if (![fs createDirectoryNamed:folderName inDirectory:fs.rootDirectory error:error]) return created;
        EMU3Directory *made = nil;
        for (EMU3Directory *d in fs.rootDirectory.subdirectories) if ([d.name isEqualToString:folderName]) made = d;
        if (!made) return created;
        created++;
        for (NSUInteger i = start; i < start + len; i++) {
            if (self.batchCancelled) return created;
            NSError *e = nil;
            if (![fs importFileAtURL:files[i] toDirectory:made error:&e]) { if (error) *error = e; }
            if (self.batchTick) self.batchTick(files[i].lastPathComponent);
        }
    }
    for (NSURL *d in dirs) {
        if (self.batchCancelled) break;
        NSString *childName = EMU3NameFromFileName(d.lastPathComponent);
        NSString *combined = (skip || name.length == 0) ? childName : [NSString stringWithFormat:@"%@ %@", name, childName];
        created += [self _restoreFlatFolderAtURL:d name:combined filesystem:fs skipOwnNameLevel:NO error:error];
    }
    return created;
}


#pragma mark - Space check and progress sheet


static NSString *EMU3SizeString(unsigned long long bytes) {
    return EMU3FormatBytes(bytes);
}

// Collects the bank files below the given URLs (plain files as they are, folders recursively,
// only .e4b banks inside folders), with their sizes.
- (NSArray<NSURL *> *)_bankFilesIn:(NSArray<NSURL *> *)urls sizes:(NSMutableArray<NSNumber *> *)sizes {
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSURL *u in urls) {
        NSNumber *isDir = nil; [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) {
            NSDirectoryEnumerator *en = [fm enumeratorAtURL:u
                                 includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey]
                                                    options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
            for (NSURL *f in en) {
                NSNumber *d = nil; [f getResourceValue:&d forKey:NSURLIsDirectoryKey error:nil];
                if (d.boolValue || ![f.pathExtension.localizedLowercaseString isEqualToString:@"e4b"]) continue;
                NSNumber *sz = nil; [f getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
                [out addObject:f]; [sizes addObject:sz ?: @0];
            }
        } else {
            NSNumber *sz = nil; [u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
            [out addObject:u]; [sizes addObject:sz ?: @0];
        }
    }
    return out;
}

// Returns YES when the data fits. Otherwise tells the user how much is needed and available.
- (BOOL)_checkSpaceOnFilesystem:(EMU3Filesystem *)fs
                          sizes:(NSArray<NSNumber *> *)sizes
                          count:(NSUInteger)count {
    return [self _checkSpaceOnFilesystem:fs sizes:sizes count:count fitCount:NULL];
}

/// With `fitOut` the user may choose "Copy N of M" when only the first N banks fit; *fitOut then holds N.
- (BOOL)_checkSpaceOnFilesystem:(EMU3Filesystem *)fs
                          sizes:(NSArray<NSNumber *> *)sizes
                          count:(NSUInteger)count
                       fitCount:(NSUInteger *)fitOut {
    if (fitOut) *fitOut = count;
    if (EMU3IsBoardUSBVolume(fs.imageURL)) {
        EMU3ShowBoardUSBRefusal(@"Copying banks into an image on that card");
        return NO;
    }
    unsigned long long clusterBytes = (unsigned long long)fs.clusterBlocks * EMU3_BLOCK_SIZE;
    if (clusterBytes == 0) return YES;
    unsigned long long needClusters = 0, rawBytes = 0;
    for (NSNumber *n in sizes) {
        unsigned long long b = n.unsignedLongLongValue; rawBytes += b;
        needClusters += MAX(1ULL, (b + clusterBytes - 1) / clusterBytes);
    }
    unsigned long long needBytes = needClusters * clusterBytes;
    unsigned long long freeBytes = (unsigned long long)fs.freeBlocks * EMU3_BLOCK_SIZE;
    if (needBytes <= freeBytes && gDropAlreadyConfirmed) {
        gDropAlreadyConfirmed = NO;
        return YES;
    }
    gDropAlreadyConfirmed = NO;
    if (needBytes <= freeBytes) {
        // Enough room: tell the user what is about to be copied and let them confirm.
        NSString *title = [NSString stringWithFormat:@"Copy %lu bank(s) to \"%@\"?",
                           (unsigned long)count, fs.imageURL.lastPathComponent ?: @"image"];
        NSString *body = [NSString stringWithFormat:
            @"Selected: %lu bank(s), %@ of data\nSpace needed: %@ (%llu cluster(s) of %@)\n"
            @"Free on the image: %@\nLeft afterwards: %@",
            (unsigned long)count, EMU3SizeString(rawBytes), EMU3SizeString(needBytes), needClusters,
            EMU3SizeString(clusterBytes), EMU3SizeString(freeBytes), EMU3SizeString(freeBytes - needBytes)];
        return EMU3RunCenteredConfirm(title, body, @"Copy", @"Cancel");
    }

    unsigned long long freeClusters = freeBytes / clusterBytes;
    NSUInteger fit = 0;
    if (fitOut) {
        unsigned long long used = 0;
        for (NSNumber *n in sizes) {
            unsigned long long c = MAX(1ULL, (n.unsignedLongLongValue + clusterBytes - 1) / clusterBytes);
            if (used + c > freeClusters) break;
            used += c; fit++;
        }
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = @"Not enough free space on the destination";
    a.informativeText = [NSString stringWithFormat:
        @"Copying %lu bank(s) (%@ of data) needs %@ on \"%@\", because every bank occupies whole %@ clusters (%llu clusters needed).\n\n"
        @"Free space: %@ (%llu clusters).\nMissing: %@.\n\nNothing was copied. Delete banks on the destination or choose a larger image.",
        (unsigned long)count, EMU3SizeString(rawBytes), EMU3SizeString(needBytes),
        fs.imageURL.lastPathComponent ?: @"image", EMU3SizeString(clusterBytes), needClusters,
        EMU3SizeString(freeBytes), freeClusters, EMU3SizeString(needBytes - freeBytes)];
    if (fitOut && fit > 0) {
        a.informativeText = [a.informativeText stringByReplacingOccurrencesOfString:@"Nothing was copied. Delete banks on the destination or choose a larger image."
            withString:[NSString stringWithFormat:@"Only the first %lu of %lu bank(s) fit. You can copy those, or cancel and make room first (delete banks on the destination or choose a larger image).", (unsigned long)fit, (unsigned long)count]];
        [a addButtonWithTitle:[NSString stringWithFormat:@"Copy %lu of %lu", (unsigned long)fit, (unsigned long)count]];
        [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] == NSAlertFirstButtonReturn) { *fitOut = fit; return YES; }
        return NO;
    }
    [a addButtonWithTitle:@"OK"];
    [a runModal];
    return NO;
}

- (void)_showProgressTitle:(NSString *)title detail:(NSString *)detail total:(NSUInteger)total {
    [self _hideProgress];
    self.batchCancelled = NO;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 140)
                                              styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView *cv = w.contentView;
    NSTextField *t = [NSTextField labelWithString:title];
    t.font = [NSFont boldSystemFontOfSize:13];
    t.frame = NSMakeRect(20, 106, 380, 18);
    NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 78, 380, 14)];
    bar.style = NSProgressIndicatorStyleBar; bar.indeterminate = NO;
    bar.minValue = 0; bar.maxValue = MAX(total, 1); bar.doubleValue = 0;
    NSTextField *d = [NSTextField labelWithString:detail ?: @""];
    d.frame = NSMakeRect(20, 40, 380, 30);
    d.font = [NSFont systemFontOfSize:11]; d.textColor = NSColor.secondaryLabelColor;
    d.lineBreakMode = NSLineBreakByTruncatingMiddle;
    d.maximumNumberOfLines = 2;
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(_cancelBatch:)];
    cancel.bezelStyle = NSBezelStyleRegularSquare;
    cancel.frame = NSMakeRect(320, 8, 80, 28);
    cancel.keyEquivalent = @"\e";
    [cv addSubview:t]; [cv addSubview:bar]; [cv addSubview:d]; [cv addSubview:cancel];
    self.progressSheet = w; self.progressBar = bar; self.progressDetail = d;
    [self.window beginSheet:w completionHandler:nil];
}

- (void)_updateProgress:(NSUInteger)done of:(NSUInteger)total name:(NSString *)name {
    self.progressBar.doubleValue = done;
    self.progressDetail.stringValue = [NSString stringWithFormat:@"%lu of %lu: %@",
                                       (unsigned long)done, (unsigned long)total, name ?: @""];
}

- (void)_hideProgress {
    if (self.progressSheet) {
        [self.window endSheet:self.progressSheet];
        [self.progressSheet orderOut:nil];
    }
    self.progressSheet = nil; self.progressBar = nil; self.progressDetail = nil;
    self.batchTick = nil;
}

- (void)_cancelBatch:(id)sender {
    self.batchCancelled = YES;
    self.progressDetail.stringValue = @"Cancelling after the current bank…";
}

- (void)_importURLs:(NSArray<NSURL *> *)urls
 toMountedFilesystem:(EMU3Filesystem *)fs
          directory:(EMU3Directory *)dropDirectory {
    NSLog(@"[Import] %lu url(s) -> %@ readOnly=%d", (unsigned long)urls.count, dropDirectory.name, fs.isReadOnly);
    if (!fs || fs.isReadOnly || urls.count == 0) { NSBeep(); return; }

    EMU3Directory *targetDir = dropDirectory ?: ((fs == self.filesystem && self.currentDirectory)
        ? self.currentDirectory
        : fs.rootDirectory);
    if (!targetDir) { NSBeep(); return; }

    // 1. Check the free space on the destination before anything is written
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    NSArray<NSURL *> *allBanks = [self _bankFilesIn:urls sizes:sizes];
    if (allBanks.count == 0) { self.statusLabel.stringValue = @"Nothing to copy (no .e4b banks found)."; return; }
    NSUInteger fitBanks = allBanks.count;
    BOOL oneBankPerURL = allBanks.count == urls.count;   // partial copy only when every dropped item is one bank file
    if (![self _checkSpaceOnFilesystem:fs sizes:sizes count:allBanks.count fitCount:oneBankPerURL ? &fitBanks : NULL]) {
        self.statusLabel.stringValue = @"Copy cancelled or not enough free space: nothing copied.";
        return;
    }
    if (fitBanks < allBanks.count) {
        urls = [urls subarrayWithRange:NSMakeRange(0, fitBanks)];
        allBanks = [allBanks subarrayWithRange:NSMakeRange(0, fitBanks)];
        sizes = [[sizes subarrayWithRange:NSMakeRange(0, fitBanks)] mutableCopy];
    }

    // 2. Progress dialog for larger jobs
    unsigned long long totalBytes = 0; for (NSNumber *n in sizes) totalBytes += n.unsignedLongLongValue;
    NSUInteger totalFiles = allBanks.count;
    BOOL showProgress = totalFiles >= 4 || totalBytes > 20ULL * 1024 * 1024;
    __block NSUInteger done = 0;
    self.batchCancelled = NO;
    if (showProgress) {
        [self _showProgressTitle:[NSString stringWithFormat:@"Copying %lu bank(s) to %@", (unsigned long)totalFiles, fs.imageURL.lastPathComponent ?: @"image"]
                          detail:[NSString stringWithFormat:@"%@ to copy, %@ free", EMU3SizeString(totalBytes),
                                  EMU3SizeString((unsigned long long)fs.freeBlocks * EMU3_BLOCK_SIZE)]
                           total:totalFiles];
        __weak typeof(self) wSelf = self;
        self.batchTick = ^(NSString *name) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done++;
                [wSelf _updateProgress:MIN(done, totalFiles) of:totalFiles name:name];
            });
        };
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:@"Importing to %@…", targetDir.name ?: @"image"];
    dispatch_async(fs.ioQueue, ^{
        NSUInteger ok = 0;
        NSError *lastErr = nil;
        for (NSURL *url in urls) {
            if (self.batchCancelled) break;
            NSError *err = nil;
            NSNumber *isDirectory = nil;
            [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
            if (isDirectory.boolValue) {
                // EOS disks have ONE level of folders (root -> folder -> banks), so folders always
                // land in the root, and deeper levels are flattened into separate root folders.
                BOOL isWholeImage = [url.path containsString:@"/EMU3ImageAsFolder/"];
                NSUInteger n = [self _restoreFlatFolderAtURL:url
                                                        name:isWholeImage ? @"" : EMU3NameFromFileName(url.lastPathComponent)
                                                  filesystem:fs
                                            skipOwnNameLevel:NO
                                                       error:&err];
                (void)isWholeImage;
                if (n > 0) ok++; else lastErr = err ?: [NSError errorWithDomain:@"EMU3" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Nothing could be copied (disk or folder list full?)"}];
            } else if ([fs importFileAtURL:url toDirectory:targetDir error:&err]) {
                ok++;
                if (self.batchTick) self.batchTick(url.lastPathComponent);
            } else {
                lastErr = err;
            }
        }
        BOOL wasCancelled = self.batchCancelled;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _hideProgress];
            if (fs == self.filesystem) {
                [self.contentCtl refresh];
                [self _updateDiskSpaceLabel];
                [self _updateBreadcrumb];
            }
            [self.mountedImagesCtl reloadData];

            NSUInteger fail = urls.count - ok;
            if (wasCancelled) { self.statusLabel.stringValue = [NSString stringWithFormat:@"Cancelled: %lu item(s) copied before stopping.", (unsigned long)ok]; return; }
            self.statusLabel.stringValue = fail == 0
                ? [NSString stringWithFormat:@"Imported %lu file(s) to %@.", (unsigned long)ok, fs.imageURL.lastPathComponent ?: @"image"]
                : [NSString stringWithFormat:@"Imported %lu file(s), %lu failed: %@",
                   (unsigned long)ok, (unsigned long)fail, lastErr.localizedDescription ?: @"unknown error"];
        });
    });
}

- (void)_importFile:(id)sender {
    if (!self.filesystem) { NSBeep(); return; }
    if (self.filesystem.isReadOnly) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Read-Only Image";
        a.informativeText = @"This image is opened read-only and cannot be modified.\n\nMake sure the .hda file is not locked and has write permissions.";
        [a runModal]; return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.message = @"Select E-MU bank file(s) or folder(s) to import (Cmd/Shift-click for multiple)";
    panel.prompt  = @"Import";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        NSArray<NSURL *> *importURLs = [panel.URLs copy];
        // Same code path as drag & drop: handles multiple files and folders.
        [self _importURLs:importURLs toMountedFilesystem:self.filesystem];
    }];
}

// Deletes a multi-selection that contains folders (and possibly files). Not undoable.
- (void)_deleteSelectionIncludingFolders {
    EMU3Filesystem *fs = self.filesystem;
    if (!fs || fs.isReadOnly) { NSBeep(); return; }

    NSArray<EMU3Directory *> *allFolders = [self _selectedFolders];
    NSMutableArray<EMU3Directory *> *folders = [NSMutableArray array];
    for (EMU3Directory *d in allFolders) {
        if (d == fs.rootDirectory || d == self.currentDirectory) continue;
        BOOL nested = NO;   // a selected ancestor already removes it
        for (EMU3Directory *a = d.parent; a; a = a.parent)
            if ([allFolders containsObject:a]) { nested = YES; break; }
        if (!nested) [folders addObject:d];
    }
    NSArray<EMU3File *> *files = [[self _selectedFiles] copy];
    NSArray<EMU3Directory *> *fileDirs = [[self _selectedFileDirectories] copy];
    if (folders.count == 0 && files.count == 0) { NSBeep(); return; }

    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = [NSString stringWithFormat:@"Delete %lu folder(s) and %lu file(s)?",
                           (unsigned long)folders.count, (unsigned long)files.count];
    confirm.informativeText = @"Everything inside the selected folders is deleted too. This cannot be undone.";
    [confirm addButtonWithTitle:@"Delete"];
    [confirm addButtonWithTitle:@"Cancel"];
    confirm.buttons[0].hasDestructiveAction = YES;
    [confirm beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        self.statusLabel.stringValue = @"Deleting…";
        dispatch_async(fs.ioQueue, ^{
            NSUInteger ok = 0, fail = 0;
            NSError *lastErr = nil;
            for (NSUInteger i = 0; i < files.count; i++) {
                EMU3Directory *fd = i < fileDirs.count ? fileDirs[i] : self.currentDirectory;
                // Skip files that live inside a folder we are about to delete anyway.
                BOOL covered = NO;
                for (EMU3Directory *a = fd; a; a = a.parent) if ([folders containsObject:a]) { covered = YES; break; }
                if (covered) continue;
                NSError *err = nil;
                if ([fs deleteFile:files[i] inDirectory:fd error:&err]) ok++; else { fail++; lastErr = err; }
            }
            for (EMU3Directory *d in folders) {
                NSError *err = nil;
                EMU3Directory *parent = d.parent ?: fs.rootDirectory;
                if ([fs deleteDirectory:d fromParent:parent error:&err]) ok++; else { fail++; lastErr = err; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.contentCtl refresh];
                [self _updateDiskSpaceLabel];
                [self.mountedImagesCtl reloadData];
                NSString *msg = [NSString stringWithFormat:@"Deleted %lu item(s).", (unsigned long)ok];
                if (fail > 0) msg = [msg stringByAppendingFormat:@" %lu failed: %@", (unsigned long)fail,
                                     lastErr.localizedDescription ?: @"unknown error"];
                self.statusLabel.stringValue = msg;
            });
        });
    }];
}

- (void)_deleteSelected:(id)sender {
    NSArray<EMU3Directory *> *selFolders = [self _selectedFolders];
    if (selFolders.count > 0) {
        if (selFolders.count == 1 && [self _selectedFiles].count == 0)
            [self _confirmDeleteFolder:selFolders.firstObject];   // single folder keeps its undo
        else
            [self _deleteSelectionIncludingFolders];
        return;
    }
    NSArray<EMU3File *> *files = [self _selectedFiles];
    if (files.count == 0) { NSBeep(); return; }
    if (self.filesystem.isReadOnly) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Read-Only Image";
        a.informativeText = @"This image is opened read-only and cannot be modified.";
        [a runModal]; return;
    }

    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = [NSString stringWithFormat:@"Delete %lu file(s)?",
                           (unsigned long)files.count];
    confirm.informativeText = @"You can undo with Cmd+Z.";
    [confirm addButtonWithTitle:@"Delete"];
    [confirm addButtonWithTitle:@"Cancel"];
    confirm.buttons[0].hasDestructiveAction = YES;

    [confirm beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        EMU3Filesystem *fs  = self.filesystem;
        EMU3Directory  *dir = self.currentDirectory;
        NSArray<EMU3File *> *toDelete = [files copy];
        NSArray<EMU3Directory *> *toDeleteDirs = [[self _selectedFileDirectories] copy];

        dispatch_async(fs.ioQueue, ^{
            // Export files to temp location before deleting (for undo)
            NSURL *tempDir = [[[NSURL fileURLWithPath:NSTemporaryDirectory()]
                                URLByAppendingPathComponent:@"EMU3Delete"]
                               URLByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            [[NSFileManager defaultManager] createDirectoryAtURL:tempDir
                                      withIntermediateDirectories:YES attributes:nil error:nil];

            NSMutableArray<NSURL *> *exportedURLs = [NSMutableArray array];
            NSMutableArray<EMU3File *> *deletedFiles = [NSMutableArray array];
            NSMutableArray<EMU3Directory *> *deletedDirs = [NSMutableArray array];

            NSError *lastErr = nil;
            for (NSUInteger fileIndex = 0; fileIndex < toDelete.count; fileIndex++) {
                EMU3File *f = toDelete[fileIndex];
                EMU3Directory *fileDir = fileIndex < toDeleteDirs.count ? toDeleteDirs[fileIndex] : dir;
                NSURL *exportURL = [tempDir URLByAppendingPathComponent:
                                   [EMU3FileSafeName(f.name) stringByAppendingString:@".E4B"]];
                NSError *exportErr = nil;
                if (![fs exportFile:f toURL:exportURL error:&exportErr]) {
                    lastErr = exportErr;
                    continue;
                }

                NSError *deleteErr = nil;
                if ([fs deleteFile:f inDirectory:fileDir error:&deleteErr]) {
                    [exportedURLs addObject:exportURL];
                    [deletedFiles addObject:f];
                    [deletedDirs addObject:fileDir];
                } else {
                    lastErr = deleteErr;
                    [[NSFileManager defaultManager] removeItemAtURL:exportURL error:nil];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [self.contentCtl refresh];
                [self _updateDiskSpaceLabel];
                NSString *countMsg = [NSString stringWithFormat:
                    @"Deleted %lu file(s).", (unsigned long)deletedFiles.count];
                if (deletedFiles.count < toDelete.count && lastErr.localizedDescription.length > 0) {
                    countMsg = [countMsg stringByAppendingFormat:@" %@", lastErr.localizedDescription];
                }
                self.statusLabel.stringValue = countMsg;

                if (deletedFiles.count > 0) {
                    self.deleteUndoBackupURLs = [exportedURLs copy];
                    self.deleteUndoDirectories = [deletedDirs copy];
                    self.deleteUndoDirectory = deletedDirs.firstObject ?: dir;
                    self.deleteRedoFiles = nil;
                    self.deleteRedoDirectory = nil;
                    self.deleteRedoDirectories = nil;
                    self.folderUndoBackupURL = nil;
                    self.folderUndoName = nil;
                    self.folderUndoParentDirectory = nil;
                    self.folderRedoName = nil;
                    self.folderRedoParentDirectory = nil;
                }
            });
        });
    }];
}

// Re-imports files from backup location and prepares redo.
- (void)_restoreFromBackup:(NSArray<NSURL *> *)backupURLs toDirectory:(EMU3Directory *)dir {
    if (!self.filesystem || self.filesystem.isReadOnly) { NSBeep(); return; }
    EMU3Filesystem *fs = self.filesystem;
    NSArray<EMU3Directory *> *restoreDirs = [self.deleteUndoDirectories copy];

    dispatch_async(fs.ioQueue, ^{
        NSMutableArray<EMU3File *> *restoredFiles = [NSMutableArray array];
        NSMutableArray<EMU3Directory *> *restoredDirs = [NSMutableArray array];
        for (NSUInteger index = 0; index < backupURLs.count; index++) {
            NSURL *url = backupURLs[index];
            EMU3Directory *targetDir = index < restoreDirs.count ? restoreDirs[index] : dir;
            NSError *importErr = nil;
            if ([fs importFileAtURL:url toDirectory:targetDir error:&importErr]) {
                for (EMU3File *f in targetDir.allFiles) {
                    if ([f.name isEqualToString:url.lastPathComponent.stringByDeletingPathExtension]) {
                        [restoredFiles addObject:f];
                        [restoredDirs addObject:targetDir];
                        break;
                    }
                }
            } else {
                NSLog(@"Restore import failed: %@", importErr);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.contentCtl refresh];
            [self _updateDiskSpaceLabel];

            if (restoredFiles.count > 0) {
                self.deleteRedoFiles = [restoredFiles copy];
                self.deleteRedoDirectories = [restoredDirs copy];
                self.deleteRedoDirectory = restoredDirs.firstObject ?: dir;
                self.deleteUndoBackupURLs = nil;
                self.deleteUndoDirectory = nil;
                self.deleteUndoDirectories = nil;
                self.folderUndoBackupURL = nil;
                self.folderUndoName = nil;
                self.folderUndoParentDirectory = nil;
                self.folderRedoName = nil;
                self.folderRedoParentDirectory = nil;
            }

            self.statusLabel.stringValue = [NSString stringWithFormat:
                @"Restored %lu file(s).", (unsigned long)restoredFiles.count];
        });
    });
}

// Deletes the restored files again and prepares undo.
- (void)_deleteRestoredFiles:(NSArray<EMU3File *> *)filesToDelete fromDirectory:(EMU3Directory *)dir {
    if (!self.filesystem || self.filesystem.isReadOnly) { NSBeep(); return; }
    EMU3Filesystem *fs = self.filesystem;
    NSArray<EMU3Directory *> *redoDirs = [self.deleteRedoDirectories copy];

    dispatch_async(fs.ioQueue, ^{
        NSURL *tempDir = [[[NSURL fileURLWithPath:NSTemporaryDirectory()]
                            URLByAppendingPathComponent:@"EMU3Delete"]
                           URLByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        [[NSFileManager defaultManager] createDirectoryAtURL:tempDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        NSMutableArray<NSURL *> *backupURLs = [NSMutableArray array];
        NSMutableArray<EMU3Directory *> *backupDirs = [NSMutableArray array];
        for (NSUInteger index = 0; index < filesToDelete.count; index++) {
            EMU3File *f = filesToDelete[index];
            EMU3Directory *fileDir = index < redoDirs.count ? redoDirs[index] : dir;
            NSURL *backupURL = [tempDir URLByAppendingPathComponent:
                               [EMU3FileSafeName(f.name) stringByAppendingString:@".E4B"]];
            NSError *exportErr = nil;
            if (![fs exportFile:f toURL:backupURL error:&exportErr]) continue;

            NSError *deleteErr = nil;
            if ([fs deleteFile:f inDirectory:fileDir error:&deleteErr]) {
                [backupURLs addObject:backupURL];
                [backupDirs addObject:fileDir];
            } else {
                [[NSFileManager defaultManager] removeItemAtURL:backupURL error:nil];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.contentCtl refresh];
            [self _updateDiskSpaceLabel];

            if (backupURLs.count > 0) {
                self.deleteUndoBackupURLs = [backupURLs copy];
                self.deleteUndoDirectories = [backupDirs copy];
                self.deleteUndoDirectory = backupDirs.firstObject ?: dir;
                self.deleteRedoFiles = nil;
                self.deleteRedoDirectory = nil;
                self.deleteRedoDirectories = nil;
                self.folderUndoBackupURL = nil;
                self.folderUndoName = nil;
                self.folderUndoParentDirectory = nil;
                self.folderRedoName = nil;
                self.folderRedoParentDirectory = nil;
            }

            self.statusLabel.stringValue = [NSString stringWithFormat:
                @"Deleted %lu file(s).", (unsigned long)backupURLs.count];
        });
    });
}

// Like _backupFolder, but a file that cannot be exported is skipped (and logged) instead of
// aborting the whole copy.
- (BOOL)_exportFolderTolerant:(EMU3Directory *)folder toURL:(NSURL *)url filesystem:(EMU3Filesystem *)fs {
    NSError *e = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:&e]) {
        NSLog(@"[Export] cannot create %@: %@", url.path, e);
        return NO;
    }
    for (EMU3File *file in folder.files) {
        NSURL *fu = [url URLByAppendingPathComponent:[EMU3FileSafeName(file.name) stringByAppendingString:@".E4B"]];
        e = nil;
        if (![fs exportFile:file toURL:fu error:&e]) NSLog(@"[Export] skipped %@: %@", file.name, e);
    }
    for (EMU3Directory *sub in folder.subdirectories)
        [self _exportFolderTolerant:sub toURL:[url URLByAppendingPathComponent:EMU3FileSafeName(sub.name ?: @"Folder")] filesystem:fs];
    return YES;
}

- (BOOL)_backupFolder:(EMU3Directory *)folder toURL:(NSURL *)backupURL filesystem:(EMU3Filesystem *)fs error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:backupURL withIntermediateDirectories:YES attributes:nil error:error]) return NO;

    for (EMU3File *file in folder.files) {
        NSURL *fileURL = [backupURL URLByAppendingPathComponent:[EMU3FileSafeName(file.name) stringByAppendingString:@".E4B"]];
        if (![fs exportFile:file toURL:fileURL error:error]) return NO;
    }

    for (EMU3Directory *subdir in folder.subdirectories) {
        NSURL *subdirURL = [backupURL URLByAppendingPathComponent:EMU3FileSafeName(subdir.name ?: @"Folder")];
        if (![self _backupFolder:subdir toURL:subdirURL filesystem:fs error:error]) return NO;
    }

    return YES;
}

- (EMU3Directory *)_restoreFolderFromBackupURL:(NSURL *)backupURL
                                          name:(NSString *)name
                                      toParent:(EMU3Directory *)parentDir
                                    filesystem:(EMU3Filesystem *)fs
                                         error:(NSError **)error {
    if (![fs createDirectoryNamed:name inDirectory:parentDir error:error]) return nil;

    EMU3Directory *restoredDir = nil;
    for (EMU3Directory *subdir in parentDir.subdirectories) {
        if ([subdir.name isEqualToString:name]) {
            restoredDir = subdir;
            break;
        }
    }
    if (!restoredDir) return nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:backupURL
                                includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                   options:0
                                                     error:error];
    if (!items) return nil;

    for (NSURL *itemURL in items) {
        NSNumber *isDirectory = nil;
        [itemURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (isDirectory.boolValue) {
            [self _restoreFolderFromBackupURL:itemURL
                                         name:EMU3NameFromFileName(itemURL.lastPathComponent)
                                     toParent:restoredDir
                                   filesystem:fs
                                        error:error];
        } else if ([[itemURL.pathExtension lowercaseString] isEqualToString:@"e4b"]) {
            [fs importFileAtURL:itemURL toDirectory:restoredDir error:error];
        }
    }

    return restoredDir;
}

- (BOOL)_createFolderNamed:(NSString *)name inDirectory:(EMU3Directory *)parentDir {
    if (!self.filesystem || self.filesystem.isReadOnly) { NSBeep(); return NO; }
    NSError *err = nil;
    if (![self.filesystem createDirectoryNamed:name inDirectory:parentDir error:&err]) {
        [[NSAlert alertWithError:err] runModal];
        return NO;
    }

    [self.contentCtl refresh];
    [self _updateDiskSpaceLabel];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Created folder \"%@\".", name];
    return YES;
}

- (void)_renameSelected:(id)sender {
    NSArray<EMU3File *> *files = [self _selectedFiles];
    if (files.count != 1) { NSBeep(); return; }
    if (self.filesystem.isReadOnly) { NSBeep(); return; }
    EMU3File *file = files.firstObject;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Rename File";
    alert.informativeText = @"Enter a new name (max 15 characters):";
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
    input.stringValue = file.name ?: @"";
    alert.accessoryView = input;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        NSString *newName = [input.stringValue stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceCharacterSet];
        if (newName.length == 0) return;
        NSError *err = nil;
        if (![self.filesystem renameFile:file newName:newName
                             inDirectory:self.currentDirectory error:&err]) {
            [[NSAlert alertWithError:err] runModal];
            return;
        }
        [self.contentCtl refresh];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Renamed to \"%@\".", newName];
    }];
    [input becomeFirstResponder];
}

// ──────────────────────────────────────────────────────────────────────────────
// Copy / Paste (Cmd+C, Cmd+V and the context menu)
// ──────────────────────────────────────────────────────────────────────────────

// Copy the selected files. The files are also exported to a temporary folder and
// put on the system pasteboard as file URLs, so they can be pasted into another
// mounted image or into Finder.
- (void)copy:(id)sender {
    NSArray<EMU3File *> *files = [[self _selectedFiles] copy];
    NSArray<EMU3Directory *> *folders = [[self _selectedFolders] copy];
    EMU3Filesystem *fs = self.filesystem;
    if ((files.count == 0 && folders.count == 0) || !fs) { NSBeep(); return; }

    self.statusLabel.stringValue = @"Copying to clipboard…";
    dispatch_async(fs.ioQueue, ^{
        NSURL *tempDir = [[[NSURL fileURLWithPath:NSTemporaryDirectory()]
                            URLByAppendingPathComponent:@"EMU3Clipboard"]
                           URLByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        [[NSFileManager defaultManager] createDirectoryAtURL:tempDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (EMU3File *f in files) {
            NSURL *url = [tempDir URLByAppendingPathComponent:
                          [EMU3FileSafeName(f.name ?: @"Untitled") stringByAppendingString:@".E4B"]];
            NSError *err = nil;
            if ([fs exportFile:f toURL:url error:&err]) [urls addObject:url];
            else NSLog(@"Copy: export failed for %@: %@", f.name, err);
        }
        for (EMU3Directory *d in folders) {
            NSURL *url = [tempDir URLByAppendingPathComponent:EMU3FileSafeName(d.name ?: @"Folder")];
            NSError *err = nil;
            if ([self _backupFolder:d toURL:url filesystem:fs error:&err]) [urls addObject:url];
            else NSLog(@"Copy: folder export failed for %@: %@", d.name, err);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (urls.count == 0) {
                NSBeep();
                self.statusLabel.stringValue = @"Copy failed.";
                return;
            }
            NSPasteboard *pb = NSPasteboard.generalPasteboard;
            [pb clearContents];
            [pb writeObjects:urls];
            self.clipFiles = folders.count ? @[] : files;   // folders always go through import
            self.clipFilesystem = fs;
            self.clipChangeCount = pb.changeCount;
            self.statusLabel.stringValue = [NSString stringWithFormat:
                @"Copied %lu file(s) to the clipboard.", (unsigned long)urls.count];
        });
    });
}

// Paste into the folder that is currently open. Files copied inside the same image
// are duplicated exactly; everything else (other images, files from Finder) is imported.
- (void)paste:(id)sender {
    EMU3Filesystem *fs = self.filesystem;
    EMU3Directory *dir = self.currentDirectory;
    if (!fs || !dir) { NSBeep(); return; }
    if (fs.isReadOnly) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Read-Only Image";
        a.informativeText = @"This image is opened read-only and cannot be modified.\n\nMake sure the .hda file is not locked and has write permissions.";
        [a runModal];
        return;
    }

    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[NSURL.class]
                                               options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls.count == 0) { NSBeep(); return; }

    BOOL internalClip = self.clipFiles.count > 0 && self.clipFilesystem == fs &&
                        pb.changeCount == self.clipChangeCount;
    if (!internalClip) {
        [self _importURLs:urls toMountedFilesystem:fs];
        return;
    }

    NSArray<EMU3File *> *files = self.clipFiles;
    NSMutableArray<NSNumber *> *psizes = [NSMutableArray array];
    for (EMU3File *f in files) [psizes addObject:@(f.fileSize)];
    NSUInteger pfit = files.count;
    if (![self _checkSpaceOnFilesystem:fs sizes:psizes count:files.count fitCount:&pfit]) return;
    if (pfit < files.count) files = [files subarrayWithRange:NSMakeRange(0, pfit)];
    self.statusLabel.stringValue = @"Pasting…";
    self.spinner.hidden = NO; [self.spinner startAnimation:nil];
    BOOL pshow = files.count >= 4;
    self.batchCancelled = NO;
    if (pshow) [self _showProgressTitle:@"Pasting banks" detail:@"" total:files.count];
    dispatch_async(fs.ioQueue, ^{
        __block NSUInteger ok = 0, fail = 0;
        for (EMU3File *f in files) {
            if (self.batchCancelled) break;
            if (pshow) { NSUInteger n = ok + fail; NSString *nm = f.name;
                dispatch_async(dispatch_get_main_queue(), ^{ [self _updateProgress:n of:files.count name:nm]; }); }
            NSError *err = nil;
            if ([fs copyFile:f toDirectory:dir error:&err]) ok++;
            else { fail++; NSLog(@"Paste failed: %@", err); }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _hideProgress];
            self.spinner.hidden = YES; [self.spinner stopAnimation:nil];
            [self.contentCtl refresh];
            [self _updateDiskSpaceLabel];
            self.statusLabel.stringValue = [NSString stringWithFormat:
                @"Pasted %lu file(s)%@.", (unsigned long)ok,
                fail > 0 ? [NSString stringWithFormat:@" (%lu failed)", (unsigned long)fail] : @""];
        });
    });
}

- (void)_copyToDir:(id)sender {
    [self _transferFiles:[self _selectedFiles] move:NO];
}
- (void)_moveToDir:(id)sender {
    [self _transferFiles:[self _selectedFiles] move:YES];
}

- (void)_transferFiles:(NSArray<EMU3File *> *)files move:(BOOL)isMove {
    if (files.count == 0 || !self.filesystem || self.filesystem.isReadOnly) { NSBeep(); return; }

    NSArray<EMU3Directory *> *dirs = [self _allDirectories:self.filesystem.rootDirectory];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = isMove ? @"Move To Directory" : @"Copy To Directory";
    alert.informativeText = @"Select a destination directory:";
    [alert addButtonWithTitle:isMove ? @"Move" : @"Copy"];
    [alert addButtonWithTitle:@"Cancel"];
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,260,26)];
    for (EMU3Directory *d in dirs) [popup addItemWithTitle:d.name];
    alert.accessoryView = popup;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        NSInteger sel = popup.indexOfSelectedItem;
        if (sel < 0 || sel >= (NSInteger)dirs.count) return;
        [self _doTransferFiles:files fromDirectory:self.currentDirectory
                   toDirectory:dirs[sel] move:isMove];
    }];
}

- (void)_doTransferFiles:(NSArray<EMU3File *> *)files
           fromDirectory:(EMU3Directory *)srcDir
             toDirectory:(EMU3Directory *)destDir
                    move:(BOOL)isMove {
    EMU3Filesystem *fs = self.filesystem;
    NSMutableArray<NSNumber *> *tsizes = [NSMutableArray array];
    for (EMU3File *f in files) [tsizes addObject:@(f.fileSize)];
    NSUInteger tfit = files.count;
    if (![self _checkSpaceOnFilesystem:fs sizes:tsizes count:files.count fitCount:&tfit]) return;
    if (tfit < files.count) files = [files subarrayWithRange:NSMakeRange(0, tfit)];
    self.statusLabel.stringValue = isMove ? @"Moving…" : @"Copying…";
    self.spinner.hidden = NO; [self.spinner startAnimation:nil];
    BOOL tshow = files.count >= 4;
    self.batchCancelled = NO;
    if (tshow) [self _showProgressTitle:isMove ? @"Moving banks" : @"Copying banks" detail:@"" total:files.count];

    dispatch_async(fs.ioQueue, ^{
        __block NSUInteger ok = 0, fail = 0;
        for (EMU3File *f in files) {
            if (self.batchCancelled) break;
            if (tshow) { NSUInteger n = ok + fail; NSString *nm = f.name;
                dispatch_async(dispatch_get_main_queue(), ^{ [self _updateProgress:n of:files.count name:nm]; }); }
            NSError *err = nil;
            BOOL success = isMove
                ? [fs moveFile:f fromDirectory:srcDir toDirectory:destDir error:&err]
                : [fs copyFile:f toDirectory:destDir error:&err];
            success ? ok++ : fail++;
            if (!success) NSLog(@"Transfer failed: %@", err);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _hideProgress];
            self.spinner.hidden = YES; [self.spinner stopAnimation:nil];
            [self _updateDiskSpaceLabel];
            [self _navigateToDirectory:destDir];
            self.statusLabel.stringValue = [NSString stringWithFormat:
                @"%@ %lu file(s)%@.", isMove ? @"Moved" : @"Copied", (unsigned long)ok,
                fail > 0 ? [NSString stringWithFormat:@" (%lu failed)", (unsigned long)fail] : @""];
        });
    });
}

- (NSArray<EMU3Directory *> *)_allDirectories:(EMU3Directory *)root {
    NSMutableArray *result = [NSMutableArray arrayWithObject:root];
    for (EMU3Directory *sub in root.subdirectories)
        [result addObjectsFromArray:[self _allDirectories:sub]];
    return result;
}

// Helper: Find the parent directory of a given directory
- (EMU3Directory *)_findParentOf:(EMU3Directory *)target inDirectory:(EMU3Directory *)search {
    if (!target || !search) return nil;


    // Check if target is a direct child
    for (EMU3Directory *subdir in search.subdirectories) {
        if (subdir == target) {
            return search;
        }
    }

    // Recursively search subdirectories
    for (EMU3Directory *subdir in search.subdirectories) {
        EMU3Directory *parent = [self _findParentOf:target inDirectory:subdir];
        if (parent) return parent;
    }

    return nil;
}

// Navigate back to parent directory
- (void)_goBackFolder:(id)sender {
    NSLog(@"[BACK] Back button clicked");
    NSLog(@"[BACK] History count: %lu", (unsigned long)self.navigationHistory.count);

    if (self.navigationHistory.count < 2) {
        NSLog(@"[BACK] Can't go back - at root of history");
        NSBeep();
        return;
    }

    // Remove current directory from history
    [self.navigationHistory removeLastObject];

    // Navigate to previous directory
    EMU3Directory *prevDir = self.navigationHistory.lastObject;
    NSLog(@"[BACK] Going back to: %@", prevDir.name);

    self.currentDirectory = prevDir;
    self.contentCtl.directory = prevDir;
    self.pendingMetadataDirectory = prevDir;

    [self.contentCtl refresh];
    [self _updateBreadcrumb];

    self.statusLabel.stringValue = [self _statusTextForDirectory:prevDir filesystem:self.filesystem];
    [self _updateMountStatusLabel];
}

// Navigate to breadcrumb segment
- (void)_navigationBreadcrumbClicked:(NSButton *)sender {
    NSLog(@"[BREADCRUMB] Clicked breadcrumb button with tag: %ld", (long)sender.tag);
    NSLog(@"[BREADCRUMB] Breadcrumb path count: %lu", (unsigned long)self.breadcrumbPath.count);

    if (!self.breadcrumbPath || sender.tag < 0 || sender.tag >= (NSInteger)self.breadcrumbPath.count) {
        NSLog(@"[BREADCRUMB] ❌ Invalid path or tag");
        NSBeep();
        return;
    }

    EMU3Directory *targetDir = self.breadcrumbPath[sender.tag];
    NSLog(@"[BREADCRUMB] ✅ Navigating to: %@", targetDir.name);
    [self _navigateToDirectory:targetDir];
}

- (void)_newFolder:(id)sender {
    [self _showNewFolderSheetInDirectory:self.currentDirectory];
}

- (void)_newFolderInSelectedFolder:(id)sender {
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    NSInteger row = ov.selectedRow;
    id item = row >= 0 ? [ov itemAtRow:row] : nil;
    if (![item isKindOfClass:[EMU3Directory class]]) { NSBeep(); return; }

    [self _showNewFolderSheetInDirectory:(EMU3Directory *)item];
}

- (void)_showNewFolderSheetInDirectory:(EMU3Directory *)parentDir {
    if (!self.filesystem || self.filesystem.isReadOnly) { NSBeep(); return; }
    if (!parentDir) { NSBeep(); return; }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"New Folder";
    alert.informativeText = [NSString stringWithFormat:@"Create a folder inside \"%@\" (max 15 characters):", parentDir.name ?: @"Current Folder"];
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
    input.stringValue = @"New Folder";
    alert.accessoryView = input;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;

        NSString *folderName = [input.stringValue stringByTrimmingCharactersInSet:
                                NSCharacterSet.whitespaceCharacterSet];
        if (folderName.length == 0) { NSBeep(); return; }

        if (folderName.length > 15) {
            folderName = [folderName substringToIndex:15];
        }

        if ([self _createFolderNamed:folderName inDirectory:parentDir] && parentDir != self.currentDirectory) {
            [self _navigateToDirectory:parentDir];
        }
    }];

    [input becomeFirstResponder];
}

- (void)_confirmDeleteFolder:(EMU3Directory *)folder {
    if (!folder || !self.filesystem || self.filesystem.isReadOnly) { NSBeep(); return; }
    if (folder == self.filesystem.rootDirectory || folder == self.currentDirectory) {
        self.statusLabel.stringValue = @"Cannot delete this folder from here.";
        NSBeep();
        return;
    }

    EMU3Directory *parentDir = [self _findParentOf:folder inDirectory:self.filesystem.rootDirectory];
    if (!parentDir) {
        self.statusLabel.stringValue = @"Delete failed: parent folder not found.";
        NSBeep();
        return;
    }

    NSString *warningMsg = folder.subdirectories.count > 0 || folder.files.count > 0
        ? [NSString stringWithFormat:@"This folder contains %lu item(s). All contents will be deleted.",
           folder.subdirectories.count + folder.files.count]
        : @"Are you sure you want to delete this folder?";

    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = [NSString stringWithFormat:@"Delete folder \"%@\"?", folder.name];
    confirm.informativeText = warningMsg;
    [confirm addButtonWithTitle:@"Delete"];
    [confirm addButtonWithTitle:@"Cancel"];
    confirm.buttons[0].hasDestructiveAction = YES;
    [confirm beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSAlertFirstButtonReturn) {
            [self _deleteFolderObject:folder parent:parentDir];
        }
    }];
}

- (void)_deleteFolderObject:(EMU3Directory *)folder parent:(EMU3Directory *)parentDir {
    if (!folder || !parentDir || !self.filesystem || self.filesystem.isReadOnly) { NSBeep(); return; }
    EMU3Filesystem *fs = self.filesystem;
    NSString *folderName = folder.name ?: @"Folder";
    self.statusLabel.stringValue = @"Deleting folder…";

    dispatch_async(fs.ioQueue, ^{
        NSError *err = nil;
        NSURL *backupURL = [[[NSURL fileURLWithPath:NSTemporaryDirectory()]
                              URLByAppendingPathComponent:@"EMU3FolderDelete"]
                             URLByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        BOOL backedUp = [self _backupFolder:folder toURL:backupURL filesystem:fs error:&err];
        BOOL success = backedUp && [fs deleteDirectory:folder fromParent:parentDir error:&err];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                if (err) [[NSAlert alertWithError:err] runModal];
                self.statusLabel.stringValue = @"Delete failed.";
                return;
            }

            self.folderUndoBackupURL = backupURL;
            self.folderUndoName = folderName;
            self.folderUndoParentDirectory = parentDir;
            self.folderRedoName = nil;
            self.folderRedoParentDirectory = nil;
            self.deleteUndoBackupURLs = nil;
            self.deleteUndoDirectory = nil;
            self.deleteUndoDirectories = nil;
            self.deleteRedoFiles = nil;
            self.deleteRedoDirectory = nil;
            self.deleteRedoDirectories = nil;

            [self.contentCtl refresh];
            [self _updateDiskSpaceLabel];
            self.statusLabel.stringValue = [NSString stringWithFormat:@"Deleted folder \"%@\".", folderName];
        });
    });
}

- (void)_deleteFolder:(id)sender {
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    NSInteger row = ov.selectedRow;
    if (row < 0) { NSBeep(); return; }

    id item = [ov itemAtRow:row];
    if (![item isKindOfClass:[EMU3Directory class]]) { NSBeep(); return; }
    [self _confirmDeleteFolder:(EMU3Directory *)item];
}

- (void)_renameFolder:(id)sender {
    // Get the selected folder
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    NSInteger row = ov.selectedRow;
    if (row < 0) { NSBeep(); return; }

    id item = [ov itemAtRow:row];
    if (![item isKindOfClass:[EMU3Directory class]]) { NSBeep(); return; }

    EMU3Directory *folder = (EMU3Directory *)item;

    if (!self.filesystem || self.filesystem.isReadOnly) { NSBeep(); return; }

    // Can't rename root
    if (folder == self.filesystem.rootDirectory) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Cannot Rename Root Folder";
        alert.informativeText = @"The root directory cannot be renamed.";
        [alert runModal];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Rename Folder";
    alert.informativeText = @"Enter a new folder name (max 15 characters):";
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
    input.stringValue = folder.name ?: @"";
    alert.accessoryView = input;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;

        NSString *newName = [input.stringValue stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceCharacterSet];
        if (newName.length == 0) { NSBeep(); return; }

        // Limit to 15 characters
        if (newName.length > 15) {
            newName = [newName substringToIndex:15];
        }

        NSError *err = nil;
        if (![self.filesystem renameDirectory:folder newName:newName error:&err]) {
            NSAlert *errorAlert = [NSAlert alertWithError:err];
            [errorAlert runModal];
            return;
        }
        [self.mountedImagesCtl reloadData];

        // Refresh to show the renamed folder
        [self.contentCtl refresh];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Renamed to \"%@\".", newName];
    }];

    [input becomeFirstResponder];
}

// Tabbed Get Info panel for folders and multi-selections (right-click ▸ Get Info…).
- (void)_showInfoForItems:(NSArray *)items filesystem:(EMU3Filesystem *)fs {
    @try { [self _showInfoForItemsImpl:items filesystem:fs]; }
    @catch (NSException *e) { NSLog(@"[Info] EXCEPTION %@: %@\n%@", e.name, e.reason, e.callStackSymbols); }
}

- (void)_showInfoForItemsImpl:(NSArray *)items filesystem:(EMU3Filesystem *)fs {
    if (items.count == 0 || !fs) { NSBeep(); return; }
    if (items.count == 1 && [items.firstObject isKindOfClass:[EMU3File class]]) {
        [self _showFileInfo:items.firstObject];
        return;
    }
    unsigned long long clusterBytes = (unsigned long long)fs.clusterBlocks * EMU3_BLOCK_SIZE;
    NSMutableSet<EMU3File *> *seen = [NSMutableSet set];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    __block NSUInteger folderCount = 0;
    void (^addFile)(EMU3File *, NSString *) = ^(EMU3File *f, NSString *folder) {
        if ([seen containsObject:f]) return;
        [seen addObject:f];
        unsigned long long sz = f.fileSize;
        unsigned long long disk = clusterBytes ? MAX(1ULL, (sz + clusterBytes - 1) / clusterBytes) * clusterBytes : sz;
        [rows addObject:@{ @"name": f.name ?: @"", @"folder": folder ?: @"", @"type": f.fileTypeString ?: @"",
                           @"size": @(sz), @"disk": @(disk), @"file": f }];
    };
    __block void (^walk)(EMU3Directory *, NSString *) = nil;
    walk = ^(EMU3Directory *d, NSString *path) {
        NSString *here = path.length ? [path stringByAppendingFormat:@" / %@", d.name ?: @""] : (d.name ?: @"");
        for (EMU3File *f in d.files) addFile(f, here);
        for (EMU3Directory *sub in d.subdirectories) { folderCount++; walk(sub, here); }
    };
    NSUInteger selFolders = 0, selFiles = 0;
    for (id it in items) {
        if ([it isKindOfClass:[EMU3Directory class]]) { selFolders++; walk(it, @""); }
        else if ([it isKindOfClass:[EMU3File class]]) { selFiles++; addFile(it, @""); }
    }
    walk = nil;

    // Bank/preset/sample counts need the bank headers: only read them for a reasonable number of files.
    NSString *contents = nil;
    if (rows.count <= 80) {
        NSDictionary<NSString *, NSNumber *> *stats = @{@"folders": @0, @"banks": @0, @"presets": @0, @"samples": @0};
        for (NSDictionary *r in rows) {
            EMU3File *f = r[@"file"];
            if (f.fileType == EMU3FileTypeBank) [fs populateBankMetadata:f error:nil];
            stats = [self _statsByAdding:stats to:[self _statsForFile:f filesystem:fs]];
        }
        contents = [self _summaryStringForStats:stats];
    }
    unsigned long long data = 0, onDisk = 0, biggest = 0; NSString *biggestName = nil;
    for (NSDictionary *r in rows) {
        data += [r[@"size"] unsignedLongLongValue]; onDisk += [r[@"disk"] unsignedLongLongValue];
        if ([r[@"size"] unsignedLongLongValue] > biggest) { biggest = [r[@"size"] unsignedLongLongValue]; biggestName = r[@"name"]; }
    }
    unsigned long long total = (unsigned long long)fs.totalBlocks * EMU3_BLOCK_SIZE;
    unsigned long long freeB = (unsigned long long)fs.freeBlocks * EMU3_BLOCK_SIZE;

    NSMutableArray<NSString *> *sel = [NSMutableArray array];
    if (selFolders) [sel addObject:[NSString stringWithFormat:@"%lu folder%@", (unsigned long)selFolders, selFolders == 1 ? @"" : @"s"]];
    if (selFiles) [sel addObject:[NSString stringWithFormat:@"%lu file%@", (unsigned long)selFiles, selFiles == 1 ? @"" : @"s"]];
    NSString *title = (items.count == 1 && [items.firstObject isKindOfClass:[EMU3Directory class]])
        ? [NSString stringWithFormat:@"Folder “%@”", ((EMU3Directory *)items.firstObject).name ?: @""]
        : [NSString stringWithFormat:@"%lu items selected", (unsigned long)items.count];

    NSArray<NSArray<NSString *> *> *general = @[
        @[@"Selected", [sel componentsJoinedByString:@", "]],
        @[@"Contains", [NSString stringWithFormat:@"%lu file%@%@", (unsigned long)rows.count, rows.count == 1 ? @"" : @"s",
                        folderCount ? [NSString stringWithFormat:@" in %lu subfolder%@", (unsigned long)folderCount, folderCount == 1 ? @"" : @"s"] : @""]],
        @[@"Content", contents.length ? contents : @"not counted (too many files)"],
        @[@"Image", fs.imageURL.lastPathComponent ?: @""],
        @[@"Volume", fs.volumeLabel.length ? fs.volumeLabel : @"—"],
    ];
    NSArray<NSArray<NSString *> *> *sizes = @[
        @[@"Data size", EMU3SizeString(data)],
        @[@"On disk", [NSString stringWithFormat:@"%@ (whole %@ clusters)", EMU3SizeString(onDisk), EMU3SizeString(clusterBytes)]],
        @[@"Share of image", total ? [NSString stringWithFormat:@"%.1f%% of %@", 100.0 * onDisk / total, EMU3SizeString(total)] : @"—"],
        @[@"Free on image", EMU3SizeString(freeB)],
        @[@"Largest", biggestName ? [NSString stringWithFormat:@"%@ (%@)", biggestName, EMU3SizeString(biggest)] : @"—"],
    ];

    // ---- Finder-style window: header + collapsible sections ----
    const CGFloat W = 400;
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, 300)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                                                  backing:NSBackingStoreBuffered defer:NO];
    panel.title = [NSString stringWithFormat:@"%@ Info", items.count == 1 && [items.firstObject isKindOfClass:[EMU3Directory class]]
                   ? (((EMU3Directory *)items.firstObject).name ?: @"Folder") : @"Selection"];
    panel.releasedWhenClosed = NO;
    panel.floatingPanel = NO;

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, W, 300)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(16, 18, 16, 18);
    [stack.widthAnchor constraintEqualToConstant:W].active = YES;

    // header: icon, title, subtitle
    NSImageView *icon = [NSImageView imageViewWithImage:(items.count == 1 && [items.firstObject isKindOfClass:[EMU3Directory class]])
                         ? [NSImage imageNamed:NSImageNameFolder] : NSApp.applicationIconImage];
    [icon.widthAnchor constraintEqualToConstant:48].active = YES;
    [icon.heightAnchor constraintEqualToConstant:48].active = YES;
    NSTextField *tl = [NSTextField labelWithString:title];
    tl.font = [NSFont boldSystemFontOfSize:15];
    NSTextField *sub = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ — %@",
                        [NSString stringWithFormat:@"%lu file%@", (unsigned long)rows.count, rows.count == 1 ? @"" : @"s"], EMU3SizeString(data)]];
    sub.font = [NSFont systemFontOfSize:12]; sub.textColor = NSColor.secondaryLabelColor;
    NSStackView *titles = [NSStackView stackViewWithViews:@[tl, sub]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical; titles.alignment = NSLayoutAttributeLeading; titles.spacing = 2;
    NSStackView *header = [NSStackView stackViewWithViews:@[icon, titles]];
    header.spacing = 12; header.alignment = NSLayoutAttributeCenterY;
    [stack addArrangedSubview:header];

    NSMutableArray<EMU3InfoToggler *> *togglers = [NSMutableArray array];
    NSMutableString *plain = [NSMutableString stringWithFormat:@"%@\n", title];
    NSView *(^kvGrid)(NSArray<NSArray<NSString *> *> *) = ^NSView *(NSArray<NSArray<NSString *> *> *pairs) {
        NSMutableArray *grid = [NSMutableArray array];
        for (NSArray<NSString *> *pr in pairs) {
            NSTextField *k = [NSTextField labelWithString:[pr[0] stringByAppendingString:@":"]];
            k.font = [NSFont systemFontOfSize:12]; k.textColor = NSColor.secondaryLabelColor; k.alignment = NSTextAlignmentRight;
            NSTextField *v = [NSTextField wrappingLabelWithString:pr[1]];
            v.font = [NSFont systemFontOfSize:12]; v.selectable = YES;
            v.preferredMaxLayoutWidth = W - 36 - 24 - 100 - 12;
            [grid addObject:@[k, v]];
            [plain appendFormat:@"%@: %@\n", pr[0], pr[1]];
        }
        NSGridView *g = [NSGridView gridViewWithViews:grid];
        g.rowSpacing = 5; g.columnSpacing = 8;
        [g columnAtIndex:0].width = 100;
        [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        return g;
    };
    void (^addSection)(NSString *, NSView *, BOOL) = ^(NSString *name, NSView *content, BOOL expanded) {
        NSButton *tri = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 14, 14)];
        tri.bezelStyle = NSBezelStyleDisclosure; tri.title = @""; tri.buttonType = NSButtonTypePushOnPushOff;
        tri.state = expanded ? NSControlStateValueOn : NSControlStateValueOff;
        NSTextField *lbl = [NSTextField labelWithString:name];
        lbl.font = [NSFont boldSystemFontOfSize:12];
        NSStackView *hdr = [NSStackView stackViewWithViews:@[tri, lbl]];
        hdr.spacing = 6;
        content.hidden = !expanded;
        EMU3InfoToggler *t = [[EMU3InfoToggler alloc] init];
        t.content = content; t.stack = stack; t.window = panel;
        tri.target = t; tri.action = @selector(toggle:);
        [togglers addObject:t];
        NSStackView *sec = [NSStackView stackViewWithViews:@[hdr, content]];
        sec.orientation = NSUserInterfaceLayoutOrientationVertical; sec.alignment = NSLayoutAttributeLeading; sec.spacing = 6;
        [stack addArrangedSubview:sec];
    };

    addSection(@"General:", kvGrid(general), YES);
    NSView *sizeView = kvGrid(sizes);
    if (total) {
        NSLevelIndicator *bar = [[NSLevelIndicator alloc] init];
        bar.levelIndicatorStyle = NSLevelIndicatorStyleContinuousCapacity;
        bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = MIN(1.0, (double)onDisk / (double)total);
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        [bar.widthAnchor constraintEqualToConstant:W - 36 - 24].active = YES;
        [bar.heightAnchor constraintEqualToConstant:14].active = YES;
        NSStackView *sv2 = [NSStackView stackViewWithViews:@[sizeView, bar]];
        sv2.orientation = NSUserInterfaceLayoutOrientationVertical; sv2.alignment = NSLayoutAttributeLeading; sv2.spacing = 8;
        sizeView = sv2;
    }
    addSection(@"Size:", sizeView, YES);

    EMU3InfoRows *src = [[EMU3InfoRows alloc] init];
    src.rows = [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a2, NSDictionary *b2) {
        return [b2[@"size"] compare:a2[@"size"]];
    }];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, W - 36, 190)];
    sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [sv.widthAnchor constraintEqualToConstant:W - 36 - 24].active = YES;
    [sv.heightAnchor constraintEqualToConstant:190].active = YES;
    NSTableView *tv = [[NSTableView alloc] initWithFrame:sv.bounds];
    NSArray *cols = @[@[@"name", @"Name", @110], @[@"folder", @"Folder", @80], @[@"size", @"Size", @60], @[@"disk", @"On disk", @60]];
    for (NSArray *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1]; col.width = [c[2] doubleValue];
        col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c[0] ascending:YES];
        [tv addTableColumn:col];
    }
    tv.dataSource = src; tv.delegate = src;
    tv.usesAlternatingRowBackgroundColors = YES;
    tv.rowHeight = 17;
    sv.documentView = tv;
    addSection([NSString stringWithFormat:@"Items (%lu):", (unsigned long)rows.count], sv, rows.count <= 12);

    [plain appendString:@"\nItems:\n"];
    for (NSDictionary *r in src.rows)
        [plain appendFormat:@"%@\t%@\t%@\t%@\n", r[@"name"], r[@"folder"], EMU3SizeString([r[@"size"] unsignedLongLongValue]), EMU3SizeString([r[@"disk"] unsignedLongLongValue])];

    // Copy button (Cmd-C copies the text too), like a Finder info window it stays open and non-modal.
    NSButton *copy = [NSButton buttonWithTitle:@"Copy as Text" target:nil action:nil];
    copy.bezelStyle = NSBezelStyleRegularSquare;
    __block NSString *plainText = [plain copy];
    EMU3ConfirmHelper *unused = nil; (void)unused;
    NSBlockOperation *copyOp = [NSBlockOperation blockOperationWithBlock:^{
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:plainText forType:NSPasteboardTypeString];
    }];
    copy.target = copyOp;   // NSButton holds its target weakly: keep it alive with the panel (below)
    copy.action = @selector(main);
    [stack addArrangedSubview:copy];

    panel.contentView = stack;
    [stack layoutSubtreeIfNeeded];
    NSSize fit = stack.fittingSize;
    [panel setContentSize:fit];
    [panel center];
    if (!self.infoPanels) self.infoPanels = [NSMutableArray array];
    [self.infoPanels addObject:panel];
    objc_setAssociatedObject(panel, "emu3.info.keep", @[togglers, src, copyOp], OBJC_ASSOCIATION_RETAIN);
    __weak NSPanel *wp = panel;
    __block id obs = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:panel queue:nil
        usingBlock:^(NSNotification *n) {
            if (wp) [self.infoPanels removeObject:wp];
            [NSNotificationCenter.defaultCenter removeObserver:obs];
        }];
    [panel makeKeyAndOrderFront:nil];
}

// Right pane ▸ Get Info…
- (void)_showSelectionInfo:(id)sender {
    NSMutableArray *items = [NSMutableArray array];
    [items addObjectsFromArray:[self _selectedFolders]];
    [items addObjectsFromArray:[self _selectedFiles]];
    [self _showInfoForItems:items filesystem:self.filesystem];
}

// Left pane ▸ Get Info…
- (void)_showTreeFolderInfo:(id)sender {
    NSArray<EMU3Directory *> *folders = [self _treeFoldersForDelete];
    if (folders.count == 0) { NSBeep(); return; }
    EMU3Filesystem *fs = [self _filesystemOwningDirectory:folders.firstObject];
    NSMutableArray *same = [NSMutableArray array];
    for (EMU3Directory *d in folders) if ([self _filesystemOwningDirectory:d] == fs) [same addObject:d];
    [self _showInfoForItems:same filesystem:fs];
}

- (void)_showFileInfo:(EMU3File *)file {
    if (!file) return;

    // Populate bank metadata if needed
    [self.filesystem populateBankMetadata:file error:nil];

    NSString *info;
    if (file.fileType == EMU3FileTypeBank) {
        info = [NSString stringWithFormat:
            @"Name:    %@\nFormat:  %@\nSize:    %@\nPresets: %lu\nSamples: %lu",
            file.bankName ?: file.name,
            file.bankFormat == EMU3BankFormatEmulatorThree ? @"Emulator III" :
            file.bankFormat == EMU3BankFormatEmulator3X    ? @"Emulator 3X"  :
            file.bankFormat == EMU3BankFormatESI32v3       ? @"ESI-32 v3"    :
            file.bankFormat == EMU3BankFormatEmulatorIV    ? @"Emulator IV"  : @"Unknown",
            file.fileSizeString,
            (unsigned long)file.presetCount,
            (unsigned long)EMU3ResolvedSampleCount(self.filesystem, file)];
    } else {
        info = [NSString stringWithFormat:@"Name: %@\nType: %@\nSize: %@",
                file.name, file.fileTypeString, file.fileSizeString];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = file.name ?: @"File Info";
    alert.informativeText = info;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Export…"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSAlertSecondButtonReturn) [self _exportSelected:nil];
    }];
}

// ──────────────────────────────────────────────────────────────────────────────
// Undo/Redo
// ──────────────────────────────────────────────────────────────────────────────

- (void)undo:(id)sender {
    [self _undo:sender];
}

- (void)redo:(id)sender {
    [self _redo:sender];
}

- (void)deleteSelectedItem:(id)sender {
    NSOutlineView *ov = (NSOutlineView *)self.tableView;
    if (ov.selectedRowIndexes.count > 1) { [self _deleteSelected:sender]; return; }
    NSInteger row = ov.selectedRow;
    if (row < 0) {
        self.statusLabel.stringValue = @"Select an item to delete.";
        NSBeep();
        return;
    }

    id item = [ov itemAtRow:row];
    EMU3Directory *folder = [item isKindOfClass:[EMU3Directory class]] ? (EMU3Directory *)item : nil;

    if (!folder && [item isKindOfClass:[EMU3File class]]) {
        EMU3File *fileLikeFolder = (EMU3File *)item;
        for (EMU3Directory *subdir in self.currentDirectory.subdirectories) {
            if ([subdir.name isEqualToString:fileLikeFolder.name]) {
                folder = subdir;
                break;
            }
        }
    }

    if (folder) {
        [self _confirmDeleteFolder:folder];
        return;
    }

    NSArray<EMU3File *> *files = [self _selectedFiles];
    if (files.count == 0) {
        self.statusLabel.stringValue = @"Selected item is not deletable.";
        NSBeep();
        return;
    }
    [self _deleteSelected:sender];
}

- (void)_undo:(id)sender {
    if (self.imageCopyUndoFilesystem) {
        EMU3Filesystem *fs = self.imageCopyUndoFilesystem;
        NSURL *url = self.imageCopyUndoURL;

        [self.mountedFilesystems removeObject:fs];
        [self.mountedImagesCtl removeMountedFilesystem:fs];
        if (self.filesystem == fs) {
            self.filesystem = nil;
            self.currentDirectory = nil;
            self.contentCtl.filesystem = nil;
            self.contentCtl.directory = nil;
            [self.contentCtl refresh];
            if (self.mountedFilesystems.count > 0) {
                [self _selectImage:self.mountedFilesystems.lastObject];
            } else {
                [self _updateBreadcrumb];
                self.window.title = @"EMU3 Disk Manager";
                self.statusLabel.stringValue = @"No image loaded";
                self.diskSpaceLabel.stringValue = @"";
            }
        }

        self.imageCopyUndoFilesystem = nil;
        self.imageCopyUndoURL = nil;
        if (url.isFileURL) {
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        }
        [self _updateMountStatusLabel];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Undid copied image %@.", url.lastPathComponent ?: @"image"];
    } else if (self.deleteUndoBackupURLs.count > 0 && self.deleteUndoDirectory) {
        [self _restoreFromBackup:self.deleteUndoBackupURLs toDirectory:self.deleteUndoDirectory];
    } else if (self.folderUndoBackupURL && self.folderUndoName && self.folderUndoParentDirectory) {
        EMU3Filesystem *fs = self.filesystem;
        NSURL *backupURL = self.folderUndoBackupURL;
        NSString *folderName = self.folderUndoName;
        EMU3Directory *parentDir = self.folderUndoParentDirectory;
        self.statusLabel.stringValue = @"Restoring folder…";
        dispatch_async(fs.ioQueue, ^{
            NSError *err = nil;
            EMU3Directory *restored = [self _restoreFolderFromBackupURL:backupURL
                                                                   name:folderName
                                                               toParent:parentDir
                                                             filesystem:fs
                                                                  error:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!restored) {
                    if (err) [[NSAlert alertWithError:err] runModal];
                    self.statusLabel.stringValue = @"Folder restore failed.";
                    return;
                }
                self.folderRedoName = folderName;
                self.folderRedoParentDirectory = parentDir;
                self.folderUndoBackupURL = nil;
                self.folderUndoName = nil;
                self.folderUndoParentDirectory = nil;
                self.deleteUndoBackupURLs = nil;
                self.deleteUndoDirectory = nil;
                self.deleteUndoDirectories = nil;
                self.deleteRedoFiles = nil;
                self.deleteRedoDirectory = nil;
                self.deleteRedoDirectories = nil;
                [self.contentCtl refresh];
                [self _updateDiskSpaceLabel];
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Restored folder \"%@\".", folderName];
            });
        });
    } else {
        self.statusLabel.stringValue = @"Nothing to undo.";
        NSBeep();
    }
}

- (void)_redo:(id)sender {
    if (self.deleteRedoFiles.count > 0 && self.deleteRedoDirectory) {
        [self _deleteRestoredFiles:self.deleteRedoFiles fromDirectory:self.deleteRedoDirectory];
    } else if (self.folderRedoName && self.folderRedoParentDirectory) {
        EMU3Directory *folder = nil;
        for (EMU3Directory *subdir in self.folderRedoParentDirectory.subdirectories) {
            if ([subdir.name isEqualToString:self.folderRedoName]) { folder = subdir; break; }
        }
        if (folder) {
            self.deleteUndoBackupURLs = nil;
            self.deleteUndoDirectory = nil;
            self.deleteUndoDirectories = nil;
            self.deleteRedoFiles = nil;
            self.deleteRedoDirectory = nil;
            self.deleteRedoDirectories = nil;
            [self _deleteFolderObject:folder parent:self.folderRedoParentDirectory];
        } else {
            self.statusLabel.stringValue = @"Folder redo failed.";
            NSBeep();
        }
    } else {
        self.statusLabel.stringValue = @"Nothing to redo.";
        NSBeep();
    }
}

- (void)_showHelp:(id)sender {
    // Create help window if it doesn't exist
    if (!self.helpWindow) {
        NSWindow *helpWin = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 1000, 800)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered
            defer:NO];

        helpWin.title = @"EMU3 Disk Manager - Help";
        [helpWin center];

        // Create WebView to display HTML
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        WKWebView *webView = [[WKWebView alloc] initWithFrame:helpWin.contentView.bounds configuration:config];
        webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        webView.navigationDelegate = (id)self;
        [helpWin.contentView addSubview:webView];

        self.helpWindow = helpWin;
        self.helpWebView = webView;

        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray<NSString *> *candidatePaths = [NSMutableArray array];

        NSString *bundledHelp = [NSBundle.mainBundle pathForResource:@"Help" ofType:@"html"];
        if (bundledHelp.length) [candidatePaths addObject:bundledHelp];

        NSString *sourceDirectory = [@(__FILE__) stringByDeletingLastPathComponent];
        if (sourceDirectory.length) {
            [candidatePaths addObject:[sourceDirectory stringByAppendingPathComponent:@"Help.html"]];
        }

        NSString *workingDirectory = fm.currentDirectoryPath;
        if (workingDirectory.length) {
            [candidatePaths addObject:[workingDirectory stringByAppendingPathComponent:@"EMU3DiskManager/Help.html"]];
            [candidatePaths addObject:[workingDirectory stringByAppendingPathComponent:@"Help.html"]];
        }

        NSURL *helpURL = nil;
        for (NSString *path in candidatePaths) {
            BOOL isDirectory = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory) {
                helpURL = [NSURL fileURLWithPath:path];
                break;
            }
        }

        if (helpURL) {
            [webView loadFileURL:helpURL allowingReadAccessToURL:helpURL.URLByDeletingLastPathComponent];
        } else {
            NSString *fallbackHTML = @"<!doctype html><html><head><meta charset='utf-8'><style>body{font:14px -apple-system,sans-serif;margin:32px;line-height:1.5;max-width:820px}h1{font-size:30px}h2{font-size:18px;margin-top:24px}li{margin:6px 0}</style></head><body><h1>EMU3 Disk Manager Help</h1><p>Use EMU3 Disk Manager to mount, browse, edit, import, and export files from E-MU disk images.</p><h2>Mount and Browse</h2><ol><li>Click <strong>Mount</strong> and choose a .hda, .img, or .dsk image.</li><li>Select the mounted image in the left pane.</li><li>Double-click folders to open them, or use the breadcrumb path to jump back.</li></ol><h2>Edit Files</h2><ul><li><strong>New Folder</strong> creates a folder in the current directory.</li><li><strong>Import</strong> copies files into the image.</li><li><strong>Export</strong> copies selected files or folders out to your Mac.</li><li><strong>Delete</strong> removes the selected item.</li><li><strong>Undo</strong> reverts supported edit operations.</li></ul><h2>Unmount</h2><p>Select a mounted image and click <strong>Unmount</strong> before moving or replacing the source image file.</p></body></html>";
            [webView loadHTMLString:fallbackHTML baseURL:nil];
        }
    }

    [self.helpWindow makeKeyAndOrderFront:nil];
}

// WKNavigationDelegate - Open external links in default browser
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;

    // Check if this is an external link (http/https)
    if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"]) {
        // Open external links in default browser
        [[NSWorkspace sharedWorkspace] openURL:url];
        decisionHandler(WKNavigationActionPolicyCancel);
    } else {
        // Allow loading of local HTML file
        decisionHandler(WKNavigationActionPolicyAllow);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Keyboard shortcuts
// ──────────────────────────────────────────────────────────────────────────────

- (void)_setupKeyboardShortcuts {
    // Monitor keyboard events for navigation and delete
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.window != self.window) return event;

        id firstResponder = event.window.firstResponder;
        if ([firstResponder isKindOfClass:[NSTextView class]]) return event;

        NSUInteger flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        BOOL hasCommand = (flags & NSEventModifierFlagCommand) != 0;
        BOOL hasOptionOrControl = (flags & (NSEventModifierFlagOption | NSEventModifierFlagControl)) != 0;

        // Return and keypad Enter open the selected folder, or the ".." row.
        if ((event.keyCode == 36 || event.keyCode == 76) && !hasCommand && !hasOptionOrControl) {
            if ([self _openSelectedFolderOrParent]) return nil;
        }

        // ESC and plain Backspace go back to the parent folder.
        if (event.keyCode == 53 || (event.keyCode == 51 && !hasCommand && !hasOptionOrControl)) {
            if (self.navigationHistory.count > 1) {
                [self _goBackFolder:nil];
                return nil;  // Consume
            }
            NSBeep();
            return nil;
        }

        // Forward Delete, or Cmd+Backspace, deletes the selected item.
        if (event.keyCode == 117 || (event.keyCode == 51 && hasCommand)) {
            [self deleteSelectedItem:nil];
            return nil;
        }

        return event;
    }];
}

- (void)_setupNotificationObservers {
    // When bank metadata is populated asynchronously, refresh the table to show updated counts
    [[NSNotificationCenter defaultCenter] addObserverForName:@"EMU3BankMetadataUpdated"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        EMU3File *file = (EMU3File *)note.object;
        if (file && [file isKindOfClass:[EMU3File class]]) {
            // Find the row index of this file and refresh it
            // self.tableView is an NSOutlineView (ClickableOutlineView)
            NSOutlineView *ov = (NSOutlineView *)self.tableView;
            NSInteger rowIndex = [ov rowForItem:file];
            if (rowIndex >= 0) {
                NSIndexSet *cols = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, ov.numberOfColumns)];
                [ov reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:rowIndex] columnIndexes:cols];
            }
        }
    }];
}

@end
