#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <fcntl.h>
#import <sys/file.h>
#import <unistd.h>

static NSString *APDataDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"AGENT_PENDING_DATA_DIR"];
    if (override.length > 0) {
        return override.stringByStandardizingPath;
    }
    NSString *applicationSupport = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory,
        NSUserDomainMask,
        YES
    ).firstObject;
    return [applicationSupport stringByAppendingPathComponent:@"Agent Pending"];
}

static NSString *APDataFile(void) {
    return [APDataDirectory() stringByAppendingPathComponent:@"store.json"];
}

static NSString *APLockFile(void) {
    return [APDataDirectory() stringByAppendingPathComponent:@"store.lock"];
}

@protocol PendingControllerDelegate <NSObject>
- (void)editItemWithIdentifier:(NSString *)identifier;
- (void)completeItemWithIdentifier:(NSString *)identifier;
- (void)quitApplication;
@end

@interface PendingViewController : NSViewController
@property(nonatomic, weak) id<PendingControllerDelegate> delegate;
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSTextField *countLabel;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSStackView *itemStack;
- (instancetype)initWithDelegate:(id<PendingControllerDelegate>)delegate;
- (void)updateItems:(NSArray<NSDictionary *> *)items;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, PendingControllerDelegate, UNUserNotificationCenterDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, strong) PendingViewController *pendingController;
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSMutableSet<NSString *> *knownIdentifiers;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, strong) NSMenu *statusMenu;
@property(nonatomic, assign) BOOL initialLoadFinished;
- (NSMutableDictionary *)mutableStoreFromDisk:(NSError **)error;
- (BOOL)writeStore:(NSDictionary *)store error:(NSError **)error;
@end

// NSApplication.delegate is weak. Keep the delegate alive for the full process lifetime.
static AppDelegate *APSharedDelegate;

static NSTextField *APLabel(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = font;
    label.textColor = color;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

static NSButton *APIconButton(NSString *symbol, NSString *toolTip, id target, SEL action) {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:toolTip]
                                          target:target
                                          action:action];
    button.bordered = NO;
    button.toolTip = toolTip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:24].active = YES;
    [button.heightAnchor constraintEqualToConstant:24].active = YES;
    return button;
}

@implementation PendingViewController

- (instancetype)initWithDelegate:(id<PendingControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _delegate = delegate;
        _items = @[];
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 220)];
    self.view = root;

    NSTextField *title = APLabel(@"待确认", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor);
    self.countLabel = APLabel(@"0 项", [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);
    NSStackView *headerText = [NSStackView stackViewWithViews:@[title, self.countLabel]];
    headerText.orientation = NSUserInterfaceLayoutOrientationVertical;
    headerText.alignment = NSLayoutAttributeLeading;
    headerText.spacing = 2;
    headerText.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *header = [[NSView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:headerText];
    [NSLayoutConstraint activateConstraints:@[
        [headerText.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:14],
        [headerText.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [header.heightAnchor constraintEqualToConstant:52],
    ]];

    self.itemStack = [[NSStackView alloc] init];
    self.itemStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.itemStack.alignment = NSLayoutAttributeLeading;
    self.itemStack.spacing = 0;
    self.itemStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *documentView = [[NSView alloc] init];
    documentView.translatesAutoresizingMaskIntoConstraints = NO;
    [documentView addSubview:self.itemStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.itemStack.topAnchor constraintEqualToAnchor:documentView.topAnchor],
        [self.itemStack.leadingAnchor constraintEqualToAnchor:documentView.leadingAnchor],
        [self.itemStack.trailingAnchor constraintEqualToAnchor:documentView.trailingAnchor],
        [self.itemStack.bottomAnchor constraintEqualToAnchor:documentView.bottomAnchor],
    ]];

    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.drawsBackground = NO;
    self.scrollView.documentView = documentView;
    [documentView.widthAnchor constraintEqualToAnchor:self.scrollView.contentView.widthAnchor].active = YES;

    NSTextField *footerText = APLabel(@"新增事项请调用 $agent-pending", [NSFont systemFontOfSize:10], NSColor.secondaryLabelColor);
    NSButton *quitButton = [NSButton buttonWithTitle:@"退出" target:self action:@selector(quitClicked:)];
    quitButton.bordered = NO;
    quitButton.font = [NSFont systemFontOfSize:11];
    quitButton.contentTintColor = NSColor.secondaryLabelColor;
    quitButton.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *footer = [[NSView alloc] init];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:footerText];
    [footer addSubview:quitButton];
    [NSLayoutConstraint activateConstraints:@[
        [footer.heightAnchor constraintEqualToConstant:40],
        [footerText.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:14],
        [footerText.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [quitButton.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-14],
        [quitButton.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
    ]];

    NSBox *topDivider = [[NSBox alloc] init];
    topDivider.boxType = NSBoxSeparator;
    topDivider.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *bottomDivider = [[NSBox alloc] init];
    bottomDivider.boxType = NSBoxSeparator;
    bottomDivider.translatesAutoresizingMaskIntoConstraints = NO;

    [root addSubview:header];
    [root addSubview:topDivider];
    [root addSubview:self.scrollView];
    [root addSubview:bottomDivider];
    [root addSubview:footer];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:root.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [topDivider.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [topDivider.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [topDivider.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:topDivider.bottomAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [bottomDivider.topAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor],
        [bottomDivider.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [bottomDivider.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.topAnchor constraintEqualToAnchor:bottomDivider.bottomAnchor],
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
}

- (void)updateItems:(NSArray<NSDictionary *> *)items {
    self.items = items ?: @[];
    if (!self.isViewLoaded) {
        return;
    }
    self.countLabel.stringValue = [NSString stringWithFormat:@"%lu 项", (unsigned long)self.items.count];
    for (NSView *view in [self.itemStack.arrangedSubviews copy]) {
        [self.itemStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (self.items.count == 0) {
        NSView *empty = [[NSView alloc] init];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *emptyLabel = APLabel(@"✓  没有待处理事项", [NSFont systemFontOfSize:13], NSColor.secondaryLabelColor);
        [empty addSubview:emptyLabel];
        [NSLayoutConstraint activateConstraints:@[
            [empty.heightAnchor constraintEqualToConstant:126],
            [emptyLabel.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
            [emptyLabel.centerYAnchor constraintEqualToAnchor:empty.centerYAnchor],
        ]];
        [self.itemStack addArrangedSubview:empty];
        [empty.widthAnchor constraintEqualToAnchor:self.itemStack.widthAnchor].active = YES;
    } else {
        for (NSDictionary *item in self.items) {
            NSView *row = [self rowForItem:item];
            [self.itemStack addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:self.itemStack.widthAnchor].active = YES;
        }
    }

    CGFloat height = self.items.count == 0 ? 220 : MIN(620, 94 + self.items.count * 62);
    self.preferredContentSize = NSMakeSize(380, height);
}

- (NSView *)rowForItem:(NSDictionary *)item {
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.toolTip = item[@"workspace_path"] ?: @"";

    NSTextField *title = APLabel(item[@"title"] ?: @"", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.maximumNumberOfLines = 1;

    NSString *subtitleText = [NSString stringWithFormat:@"%@  ·  %@",
                              item[@"note"] ?: @"",
                              [self displayDate:item[@"created_at"]]];
    NSTextField *subtitle = APLabel(subtitleText, [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);
    subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    subtitle.maximumNumberOfLines = 1;

    NSStackView *textStack = [NSStackView stackViewWithViews:@[title, subtitle]];
    textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    textStack.alignment = NSLayoutAttributeLeading;
    textStack.spacing = 4;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSString *identifier = item[@"id"] ?: @"";
    NSButton *edit = APIconButton(@"pencil", @"编辑", self, @selector(editClicked:));
    edit.identifier = identifier;
    NSButton *complete = APIconButton(@"checkmark.circle", @"完成并归档", self, @selector(completeClicked:));
    complete.identifier = identifier;

    [row addSubview:textStack];
    [row addSubview:edit];
    [row addSubview:complete];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:62],
        [textStack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [textStack.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [edit.leadingAnchor constraintGreaterThanOrEqualToAnchor:textStack.trailingAnchor constant:8],
        [edit.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [complete.leadingAnchor constraintEqualToAnchor:edit.trailingAnchor constant:5],
        [complete.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [complete.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

- (NSString *)displayDate:(NSString *)rawDate {
    if (rawDate.length == 0) {
        return @"";
    }
    NSISO8601DateFormatter *parser = [[NSISO8601DateFormatter alloc] init];
    NSDate *date = [parser dateFromString:rawDate];
    if (!date) {
        return rawDate;
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"M月d日 HH:mm";
    return [formatter stringFromDate:date];
}

- (void)editClicked:(NSButton *)sender {
    [self.delegate editItemWithIdentifier:sender.identifier];
}

- (void)completeClicked:(NSButton *)sender {
    [self.delegate completeItemWithIdentifier:sender.identifier];
}

- (void)quitClicked:(id)sender {
    [self.delegate quitApplication];
}

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"Agent Pending launching with delegate %@", self);
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.knownIdentifiers = [NSMutableSet set];
    self.items = @[];

    UNUserNotificationCenter *notificationCenter = UNUserNotificationCenter.currentNotificationCenter;
    notificationCenter.delegate = self;
    [notificationCenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                       completionHandler:^(__unused BOOL granted, __unused NSError *error) {}];

    self.pendingController = [[PendingViewController alloc] initWithDelegate:self];
    self.popover = [[NSPopover alloc] init];
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.contentViewController = self.pendingController;
    self.popover.contentSize = NSMakeSize(380, 220);

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.image = [NSImage imageWithSystemSymbolName:@"tray.full" accessibilityDescription:@"Agent Pending"];
    button.target = self;
    button.action = @selector(statusItemClicked:);
    [button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    self.statusMenu = [[NSMenu alloc] initWithTitle:@"Agent Pending"];
    NSMenuItem *showItem = [[NSMenuItem alloc] initWithTitle:@"显示待确认列表"
                                                     action:@selector(showListFromMenu:)
                                              keyEquivalent:@""];
    showItem.target = self;
    [self.statusMenu addItem:showItem];
    [self.statusMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *restartItem = [[NSMenuItem alloc] initWithTitle:@"重启 Agent Pending"
                                                        action:@selector(restartApplication:)
                                                 keyEquivalent:@""];
    restartItem.target = self;
    [self.statusMenu addItem:restartItem];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"退出 Agent Pending"
                                                     action:@selector(quitApplicationFromMenu:)
                                              keyEquivalent:@""];
    quitItem.target = self;
    [self.statusMenu addItem:quitItem];

    [self refreshAndNotify:NO];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(refreshTimerFired:)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"Agent Pending terminating");
    [self.refreshTimer invalidate];
}

- (void)statusItemClicked:(NSStatusBarButton *)sender {
    NSEvent *event = NSApp.currentEvent;
    NSLog(@"Agent Pending status item click: type=%ld", (long)event.type);
    if (event.type == NSEventTypeRightMouseUp) {
        [NSMenu popUpContextMenu:self.statusMenu withEvent:event forView:sender];
        return;
    }
    [self togglePopover:sender];
}

- (void)togglePopover:(id)sender {
    if (self.popover.shown) {
        [self.popover performClose:nil];
        return;
    }
    [self.pendingController updateItems:self.items];
    [self.popover showRelativeToRect:self.statusItem.button.bounds
                              ofView:self.statusItem.button
                       preferredEdge:NSRectEdgeMinY];
}

- (void)showListFromMenu:(id)sender {
    if (!self.popover.shown) {
        [self.pendingController updateItems:self.items];
        [self.popover showRelativeToRect:self.statusItem.button.bounds
                                  ofView:self.statusItem.button
                           preferredEdge:NSRectEdgeMinY];
    }
}

- (void)restartApplication:(id)sender {
    NSLog(@"Agent Pending restarting");
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[
        @"-c",
        @"sleep 1; /usr/bin/open -n -g \"$1\"",
        @"agent-pending-restart",
        NSBundle.mainBundle.bundlePath,
    ];
    [task launchAndReturnError:nil];
    [NSApp terminate:nil];
}

- (void)quitApplicationFromMenu:(id)sender {
    [self quitApplication];
}

- (void)refreshTimerFired:(NSTimer *)timer {
    [self refreshAndNotify:YES];
}

- (void)refreshAndNotify:(BOOL)notify {
    NSError *error = nil;
    NSArray<NSDictionary *> *latest = [self readItems:&error];
    if (!latest) {
        NSLog(@"Agent Pending failed to refresh: %@", error);
        return;
    }
    NSUInteger previousCount = self.items.count;
    if (notify && self.initialLoadFinished) {
        for (NSDictionary *item in latest) {
            NSString *identifier = item[@"id"];
            if (identifier.length > 0 && ![self.knownIdentifiers containsObject:identifier]) {
                [self sendNotificationForItem:item];
            }
        }
    }
    self.items = latest;
    [self.knownIdentifiers removeAllObjects];
    for (NSDictionary *item in latest) {
        if ([item[@"id"] isKindOfClass:NSString.class]) {
            [self.knownIdentifiers addObject:item[@"id"]];
        }
    }
    self.initialLoadFinished = YES;
    [self updateStatusItem];
    [self.pendingController updateItems:latest];
    if (previousCount != latest.count) {
        NSLog(@"Agent Pending refreshed: %lu item(s)", (unsigned long)latest.count);
    }
}

- (void)updateStatusItem {
    self.statusItem.button.title = [NSString stringWithFormat:@" %lu", (unsigned long)self.items.count];
    NSString *symbol = self.items.count == 0 ? @"checkmark.circle" : @"tray.full";
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"Agent Pending"];
}

- (void)sendNotificationForItem:(NSDictionary *)item {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = item[@"title"] ?: @"新的待确认事项";
    content.body = item[@"note"] ?: @"";
    content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:item[@"id"] ?: NSUUID.UUID.UUIDString
                                                                          content:content
                                                                          trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

- (void)editItemWithIdentifier:(NSString *)identifier {
    NSDictionary *item = [self itemWithIdentifier:identifier];
    if (!item) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"编辑待确认事项";
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];

    NSTextField *titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 340, 24)];
    titleField.stringValue = item[@"title"] ?: @"";
    titleField.placeholderString = @"项目 / 事项";
    NSTextField *noteField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 340, 24)];
    noteField.stringValue = item[@"note"] ?: @"";
    noteField.placeholderString = @"等待你处理的一句话";
    NSTextField *pathLabel = APLabel(item[@"workspace_path"] ?: @"", [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular], NSColor.secondaryLabelColor);
    pathLabel.maximumNumberOfLines = 2;

    NSStackView *fields = [NSStackView stackViewWithViews:@[titleField, noteField, pathLabel]];
    fields.orientation = NSUserInterfaceLayoutOrientationVertical;
    fields.spacing = 8;
    fields.frame = NSMakeRect(0, 0, 340, 82);
    alert.accessoryView = fields;

    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    NSString *title = [titleField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *note = [noteField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (title.length == 0 || note.length == 0) {
        return;
    }

    [self modifyItems:^(NSMutableArray<NSMutableDictionary *> *items) {
        for (NSMutableDictionary *candidate in items) {
            if ([candidate[@"id"] isEqualToString:identifier]) {
                candidate[@"title"] = title;
                candidate[@"note"] = note;
                break;
            }
        }
    }];
}

- (void)completeItemWithIdentifier:(NSString *)identifier {
    [self withExclusiveLock:^BOOL(NSError **error) {
        NSMutableDictionary *store = [self mutableStoreFromDisk:error];
        if (!store) {
            return NO;
        }
        NSMutableArray *pending = store[@"pending"];
        NSUInteger index = [pending indexOfObjectPassingTest:^BOOL(
            NSDictionary *candidate,
            __unused NSUInteger candidateIndex,
            __unused BOOL *stop
        ) {
            return [candidate[@"id"] isEqualToString:identifier];
        }];
        if (index == NSNotFound) {
            return NO;
        }
        NSMutableDictionary *item = [pending[index] mutableCopy];
        NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
        item[@"completed_at"] = [formatter stringFromDate:NSDate.date];
        [pending removeObjectAtIndex:index];
        [store[@"archive"] addObject:item];
        return [self writeStore:store error:error];
    } error:nil];
    [self refreshAndNotify:NO];
}

- (void)quitApplication {
    [NSApp terminate:nil];
}

- (NSDictionary *)itemWithIdentifier:(NSString *)identifier {
    for (NSDictionary *item in self.items) {
        if ([item[@"id"] isEqualToString:identifier]) {
            return item;
        }
    }
    return nil;
}

- (void)modifyItems:(void (^)(NSMutableArray<NSMutableDictionary *> *items))mutation {
    [self withExclusiveLock:^BOOL(NSError **error) {
        NSMutableDictionary *store = [self mutableStoreFromDisk:error];
        if (!store) {
            return NO;
        }
        NSMutableArray<NSMutableDictionary *> *items = store[@"pending"];
        mutation(items);
        return [self writeStore:store error:error];
    } error:nil];
    [self refreshAndNotify:NO];
}

- (NSArray<NSDictionary *> *)readItems:(NSError **)error {
    __block NSArray<NSDictionary *> *result = nil;
    BOOL success = [self withExclusiveLock:^BOOL(NSError **innerError) {
        NSMutableDictionary *store = [self mutableStoreFromDisk:innerError];
        if (!store) {
            return NO;
        }
        NSMutableArray *items = store[@"pending"];
        [items sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [left[@"created_at"] compare:right[@"created_at"]];
        }];
        result = [items copy];
        return YES;
    } error:error];
    return success ? result : nil;
}

- (NSMutableDictionary *)mutableStoreFromDisk:(NSError **)error {
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager fileExistsAtPath:APDataFile()]) {
        NSMutableDictionary *store = [@{
            @"version": @1,
            @"pending": [NSMutableArray array],
            @"archive": [NSMutableArray array],
        } mutableCopy];
        if (![self writeStore:store error:error]) {
            return nil;
        }
        return store;
    }
    NSData *data = [NSData dataWithContentsOfFile:APDataFile() options:0 error:error];
    if (!data) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error];
    if ([object isKindOfClass:NSArray.class]) {
        object = @{
            @"version": @1,
            @"pending": object,
            @"archive": @[],
        };
    }
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"version"] isEqual:@1]) {
        return nil;
    }
    NSMutableArray *pending = [object[@"pending"] mutableCopy];
    NSMutableArray *archive = [object[@"archive"] mutableCopy];
    if (!pending || !archive) {
        return nil;
    }
    return [@{
        @"version": @1,
        @"pending": pending,
        @"archive": archive,
    } mutableCopy];
}

- (BOOL)writeStore:(NSDictionary *)store error:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:store
                                                   options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                                     error:error];
    if (!data) {
        return NO;
    }
    return [data writeToFile:APDataFile() options:NSDataWritingAtomic error:error];
}

- (BOOL)withExclusiveLock:(BOOL (^)(NSError **error))operation error:(NSError **)error {
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtPath:APDataDirectory()
             withIntermediateDirectories:YES
                              attributes:nil
                                   error:error]) {
        return NO;
    }
    int descriptor = open(APLockFile().fileSystemRepresentation, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        return NO;
    }
    if (flock(descriptor, LOCK_EX) != 0) {
        close(descriptor);
        return NO;
    }
    BOOL result = operation(error);
    flock(descriptor, LOCK_UN);
    close(descriptor);
    return result;
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

@end

int main(__unused int argc, __unused const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        APSharedDelegate = [[AppDelegate alloc] init];
        application.delegate = APSharedDelegate;
        [application run];
    }
    return 0;
}
