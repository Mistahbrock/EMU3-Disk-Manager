#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // AppKit adds AutoFill, Writing Tools and Emoji & Symbols to every Edit menu: switch off what can be switched off.
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            @"NSDisabledCharacterPaletteMenuItem": @YES,
            @"NSAutoFillHeuristicControllerEnabled": @NO}];
        NSWindow.allowsAutomaticWindowTabbing = NO;   // removes "Show Tab Bar" / "Show All Tabs" from the View menu
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
