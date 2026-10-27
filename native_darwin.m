// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

#import <Cocoa/Cocoa.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_types.h>
#include <net/route.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <signal.h>
#include "bridge.h"
#include "_cgo_export.h"

// Reuse the routing snapshot buffer: normally one syscall per sample.
int scaler_counters(ScalerCounter *out, int capacity) {
    static char *buffer;
    static size_t allocated;
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t length = allocated;
    for (int attempt = 0; attempt < 3; attempt++) {
        if (!allocated) {
            if (sysctl(mib, 6, NULL, &length, NULL, 0) < 0) return -errno;
            size_t wanted = length + 4096;
            char *grown = realloc(buffer, wanted);
            if (!grown) return -ENOMEM;
            buffer = grown; allocated = wanted;
        }
        length = allocated;
        if (sysctl(mib, 6, buffer, &length, NULL, 0) == 0) break;
        if (errno != ENOMEM) return -errno;
        allocated = 0;
        if (attempt == 2) return -ENOMEM;
    }
    int count = 0;
    struct message_prefix { unsigned short ifm_msglen; unsigned char version, ifm_type; };
    for (size_t offset = 0; offset + sizeof(struct message_prefix) <= length;) {
        struct message_prefix *header = (struct message_prefix *)(buffer + offset);
        size_t size = header->ifm_msglen;
        if (size < sizeof(*header) || size > length - offset) return -EINVAL;
        if (header->ifm_type == RTM_IFINFO2 && size >= sizeof(struct if_msghdr2)) {
            struct if_msghdr2 *info = (struct if_msghdr2 *)header;
            size_t addressOffset = sizeof(*info);
            if ((info->ifm_addrs & RTA_IFP) && size >= addressOffset + offsetof(struct sockaddr_dl, sdl_data)) {
                struct sockaddr_dl *link = (struct sockaddr_dl *)((char *)info + addressOffset);
                size_t nameLength = link->sdl_nlen;
                if (nameLength > 0 && nameLength < 16 &&
                    addressOffset + offsetof(struct sockaddr_dl, sdl_data) + nameLength <= size) {
                    if (count == capacity) return -EOVERFLOW;
                    ScalerCounter *value = &out[count++];
                    memcpy(value->name, link->sdl_data, nameLength);
                    value->name[nameLength] = 0;
                    value->index = info->ifm_index;
                    value->received = info->ifm_data.ifi_ibytes;
                    value->sent = info->ifm_data.ifi_obytes;
                }
            }
        }
        offset += size;
    }
    return count;
}

// Ask the routing table directly: VPN clients can install routes without
// updating SystemConfiguration's physical primary-interface preference.
unsigned int scaler_default_index(int family) {
    int fd = socket(PF_ROUTE, SOCK_RAW, family);
    if (fd < 0) return 0;
    struct timeval timeout = {.tv_usec = 100000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct { struct rt_msghdr header; struct sockaddr_storage address; } request = {0};
    size_t addressLength = family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
    struct sockaddr *address = (struct sockaddr *)&request.address;
    address->sa_len = addressLength; address->sa_family = family;
    request.header.rtm_msglen = sizeof(struct rt_msghdr) + addressLength;
    request.header.rtm_version = RTM_VERSION;
    request.header.rtm_type = RTM_GET;
    request.header.rtm_addrs = RTA_DST;
    request.header.rtm_seq = 1;
    request.header.rtm_pid = getpid();
    unsigned int index = 0;
    if (write(fd, &request, request.header.rtm_msglen) > 0) {
        char reply[8192];
        for (int attempt = 0; attempt < 16; attempt++) {
            ssize_t size = read(fd, reply, sizeof(reply));
            if (size < (ssize_t)sizeof(struct rt_msghdr)) break;
            struct rt_msghdr *message = (struct rt_msghdr *)reply;
            if (message->rtm_pid == getpid() && message->rtm_seq == 1 && message->rtm_type == RTM_GET) {
                if (!message->rtm_errno) index = message->rtm_index;
                break;
            }
        }
    }
    close(fd);
    return index;
}

@interface ScalerApp : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(strong) NSStatusItem *status;
@property(strong) NSTimer *timer;
@property(strong) NSMenuItem *details;
@property(strong) NSMenuItem *problem;
@property(strong) NSMutableArray<NSMenuItem *> *intervalItems;
@property BOOL systemSleeping;
@property BOOL displaySleeping;
@end

static ScalerApp *controller;

@implementation ScalerApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults persistentDomainForName:@"local.gscaller.app"]) {
        NSDictionary *old = [defaults persistentDomainForName:@"local.scaler.app"];
        if (old) [defaults setPersistentDomain:old forName:@"local.gscaller.app"];
    }
    self.status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.status.button.font = [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
    ((NSButtonCell *)self.status.button.cell).wraps = YES;
    ((NSButtonCell *)self.status.button.cell).usesSingleLineMode = NO;
    self.status.button.title = @"↕ —";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"gscaller"];
    menu.delegate = self;
    NSMenuItem *heading = [menu addItemWithTitle:@"gscaller · Автовыбор сети / VPN" action:NULL keyEquivalent:@""];
    heading.enabled = NO;
    self.details = [menu addItemWithTitle:@"Сбор статистики…" action:NULL keyEquivalent:@""];
    self.problem = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    self.problem.hidden = YES;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *interval = [menu addItemWithTitle:@"Интервал обновления" action:NULL keyEquivalent:@""];
    NSMenu *choices = [[NSMenu alloc] initWithTitle:@"Интервал"];
    self.intervalItems = [NSMutableArray array];
    for (NSNumber *seconds in @[@2, @5, @10, @30]) {
        NSMenuItem *item = [choices addItemWithTitle:[NSString stringWithFormat:@"%@ секунд", seconds] action:@selector(changeInterval:) keyEquivalent:@""];
        item.tag = seconds.integerValue; item.target = self;
        [self.intervalItems addObject:item];
    }
    interval.submenu = choices;
    NSMenuItem *hint = [menu addItemWithTitle:@"Энергосбережение: минимум 10 с" action:NULL keyEquivalent:@""];
    hint.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:@"Завершить gscaller" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    NSMenuItem *mode = [[NSMenuItem alloc] initWithTitle:@"Показывать скорость в строке меню" action:@selector(changeMode:) keyEquivalent:@""];
    mode.target = self;
    if ([defaults integerForKey:@"layoutVersion"] < 2) {
        [defaults setBool:YES forKey:@"showSpeed"];
        [defaults setInteger:2 forKey:@"layoutVersion"];
    }
    BOOL speed = [defaults boolForKey:@"showSpeed"];
    mode.state = speed ? NSControlStateValueOn : NSControlStateValueOff;
    scaler_set_mode(speed);
    [menu insertItem:mode atIndex:4];
    self.status.menu = menu;
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserver:self selector:@selector(sleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(wake:) name:NSWorkspaceDidWakeNotification object:nil];
    [workspace addObserver:self selector:@selector(screenSleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(screenWake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(powerChanged:) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    scaler_tick(1);
    [self schedule];
}
- (void)schedule {
    [self.timer invalidate]; self.timer = nil;
    NSInteger chosen = [NSUserDefaults.standardUserDefaults integerForKey:@"interval"];
    if (chosen != 2 && chosen != 5 && chosen != 10 && chosen != 30) chosen = 5;
    for (NSMenuItem *item in self.intervalItems) item.state = item.tag == chosen ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.systemSleeping || self.displaySleeping) return;
    NSTimeInterval seconds = NSProcessInfo.processInfo.lowPowerModeEnabled ? MAX(chosen, 10) : chosen;
    self.timer = [NSTimer timerWithTimeInterval:seconds target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    self.timer.tolerance = seconds * 0.25;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)tick:(NSTimer *)timer { scaler_tick(0); }
- (void)changeInterval:(NSMenuItem *)item {
    [NSUserDefaults.standardUserDefaults setInteger:item.tag forKey:@"interval"];
    [self schedule];
}
- (void)changeMode:(NSMenuItem *)item {
    BOOL speed = item.state != NSControlStateValueOn;
    item.state = speed ? NSControlStateValueOn : NSControlStateValueOff;
    [NSUserDefaults.standardUserDefaults setBool:speed forKey:@"showSpeed"];
    scaler_set_mode(speed);
    scaler_tick(0);
}
- (void)powerChanged:(NSNotification *)note { [self schedule]; }
- (void)sleep:(NSNotification *)note { scaler_tick(1); scaler_save(); self.systemSleeping = YES; [self schedule]; }
- (void)wake:(NSNotification *)note { self.systemSleeping = NO; scaler_tick(1); [self schedule]; }
- (void)screenSleep:(NSNotification *)note { scaler_tick(1); scaler_save(); self.displaySleeping = YES; [self schedule]; }
- (void)screenWake:(NSNotification *)note { self.displaySleeping = NO; scaler_tick(1); [self schedule]; }
- (void)menuWillOpen:(NSMenu *)menu { scaler_tick(0); }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    scaler_tick(1); scaler_save(); return NSTerminateNow;
}
@end

void scaler_display(const char *title, const char *details, const char *error) {
    @autoreleasepool {
        NSString *text = [NSString stringWithUTF8String:title];
        if (![[controller.status.button.attributedTitle string] isEqualToString:text]) {
            NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
            paragraph.alignment = NSTextAlignmentRight;
            paragraph.minimumLineHeight = 10;
            paragraph.maximumLineHeight = 10;
            NSDictionary *attributes = @{NSFontAttributeName: controller.status.button.font,
                NSParagraphStyleAttributeName: paragraph, NSForegroundColorAttributeName: NSColor.blackColor};
            NSAttributedString *label = [[NSAttributedString alloc] initWithString:text attributes:attributes];
            controller.status.button.attributedTitle = label;
            // Draw the two rows as a single template image to avoid the
            // status button cell's large horizontal text margins.
            NSSize measured = label.size;
            NSSize size = NSMakeSize(ceil(measured.width), 20);
            NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
                [label drawInRect:rect];
                return YES;
            }];
            image.template = YES;
            controller.status.button.imagePosition = NSImageOnly;
            controller.status.button.image = image;
            controller.status.length = size.width + 6;
            [controller.status.button setAccessibilityLabel:@"gscaller"];
            [controller.status.button setAccessibilityValue:text];
            [label release]; [paragraph release];
        }
        NSString *info = [NSString stringWithUTF8String:details];
        if (![controller.details.title isEqualToString:info]) controller.details.title = info;
        controller.status.button.toolTip = info;
        controller.problem.title = [NSString stringWithUTF8String:error];
        controller.problem.hidden = !error[0];
    }
}
const char *scaler_status_title(void) { return [controller.status.button.attributedTitle.string UTF8String]; }
double scaler_status_width(void) { return controller.status.button.frame.size.width; }

void scaler_run(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // Only the packaged menu app owns this delegate for its entire lifetime.
        controller = [[ScalerApp alloc] init];
        NSApp.delegate = controller;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp run];
    }
}
