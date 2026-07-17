#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <fcntl.h>
#import <sys/file.h>
#import <unistd.h>

static NSPasteboardType const APPendingRowPasteboardType = @"io.github.georgedu.agent-pending.row";

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

static NSString *APLanguage(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"AGENT_PENDING_LANGUAGE"];
    if ([override isEqualToString:@"en"] || [override isEqualToString:@"zh"]) {
        return override;
    }
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"AgentPendingLanguage"];
    return [saved isEqualToString:@"en"] ? @"en" : @"zh";
}

static NSString *APText(NSString *key) {
    static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *strings;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        strings = @{
            @"title": @{@"zh": @"待处理", @"en": @"Action Items"},
            @"empty": @{@"zh": @"✓  没有待处理事项", @"en": @"✓  Nothing pending"},
            @"footer": @{@"zh": @"拖动排序 · + 新增 · $agent-pending", @"en": @"Drag to reorder · + · $agent-pending"},
            @"quit": @{@"zh": @"退出", @"en": @"Quit"},
            @"add": @{@"zh": @"新增", @"en": @"Add"},
            @"edit": @{@"zh": @"编辑", @"en": @"Edit"},
            @"complete": @{@"zh": @"完成并归档", @"en": @"Complete and archive"},
            @"show_list": @{@"zh": @"显示待处理事项", @"en": @"Show action items"},
            @"language": @{@"zh": @"语言", @"en": @"Language"},
            @"restart": @{@"zh": @"重启 Agent Pending", @"en": @"Restart Agent Pending"},
            @"quit_app": @{@"zh": @"退出 Agent Pending", @"en": @"Quit Agent Pending"},
            @"new_item": @{@"zh": @"新的待处理事项", @"en": @"New action item"},
            @"add_item": @{@"zh": @"新增待处理事项", @"en": @"Add action item"},
            @"edit_item": @{@"zh": @"编辑待处理事项", @"en": @"Edit action item"},
            @"save": @{@"zh": @"保存", @"en": @"Save"},
            @"cancel": @{@"zh": @"取消", @"en": @"Cancel"},
            @"item_placeholder": @{@"zh": @"项目 / 事项", @"en": @"Project / item"},
            @"note_placeholder": @{@"zh": @"等待你处理的一句话", @"en": @"One action that still needs you"},
            @"workspace_placeholder": @{@"zh": @"工作区绝对路径", @"en": @"Absolute workspace path"},
            @"title_label": @{@"zh": @"标题", @"en": @"Title"},
            @"note_label": @{@"zh": @"待处理内容", @"en": @"Pending action"},
            @"workspace_label": @{@"zh": @"工作目录", @"en": @"Workspace"},
            @"priority_label": @{@"zh": @"重要程度", @"en": @"Importance"},
            @"priority_high": @{@"zh": @"高", @"en": @"High"},
            @"priority_medium": @{@"zh": @"中", @"en": @"Medium"},
            @"priority_low": @{@"zh": @"低", @"en": @"Low"},
            @"drag_reorder": @{@"zh": @"拖动调整处理顺序", @"en": @"Drag to change processing order"},
            @"move_top": @{@"zh": @"置顶", @"en": @"Move to Top"},
            @"move_up": @{@"zh": @"上移", @"en": @"Move Up"},
            @"move_down": @{@"zh": @"下移", @"en": @"Move Down"},
            @"copy_workspace": @{@"zh": @"复制工作目录", @"en": @"Copy workspace"},
            @"workspace_copied": @{@"zh": @"已复制工作目录", @"en": @"Workspace copied"},
        };
    });
    return strings[key][APLanguage()] ?: key;
}

static NSString *APCountText(NSUInteger count) {
    if ([APLanguage() isEqualToString:@"en"]) {
        return [NSString stringWithFormat:(count == 1 ? @"%lu item" : @"%lu items"), (unsigned long)count];
    }
    return [NSString stringWithFormat:@"%lu 项", (unsigned long)count];
}

@protocol PendingControllerDelegate <NSObject>
- (void)addItem;
- (void)editItemWithIdentifier:(NSString *)identifier;
- (void)completeItemWithIdentifier:(NSString *)identifier;
- (void)reorderItemsWithIdentifiers:(NSArray<NSString *> *)identifiers;
- (void)quitApplication;
@end

@interface PendingViewController : NSViewController <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@property(nonatomic, weak) id<PendingControllerDelegate> delegate;
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSTextField *countLabel;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSTableColumn *itemColumn;
@property(nonatomic, strong) NSTextField *emptyLabel;
@property(nonatomic, assign) CGFloat contentWidth;
- (instancetype)initWithDelegate:(id<PendingControllerDelegate>)delegate;
- (void)updateItems:(NSArray<NSDictionary *> *)items;
- (void)updateContentWidthForScreen:(NSScreen *)screen;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, PendingControllerDelegate, UNUserNotificationCenterDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, strong) PendingViewController *pendingController;
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSMutableSet<NSString *> *knownIdentifiers;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, strong) NSMenu *statusMenu;
@property(nonatomic, strong) NSWindow *screenshotAnchorWindow;
@property(nonatomic, assign) BOOL initialLoadFinished;
- (NSMutableDictionary *)mutableStoreFromDisk:(NSError **)error;
- (BOOL)writeStore:(NSDictionary *)store error:(NSError **)error;
- (void)rebuildLocalizedInterface;
- (void)showScreenshotPopover;
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

static CGFloat APPreferredPopoverWidth(NSScreen *screen) {
    CGFloat screenWidth = screen ? NSWidth(screen.visibleFrame) : 1728;
    return round(MIN(640, MAX(520, screenWidth * 0.30)));
}

static NSString *APNormalizedPriority(id value) {
    if ([value isKindOfClass:NSString.class] &&
        ([(NSString *)value isEqualToString:@"high"] ||
         [(NSString *)value isEqualToString:@"low"])) {
        return value;
    }
    return @"medium";
}

static NSColor *APTechGrayColor(void) {
    static NSColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [NSColor colorWithName:@"AgentPendingTechGray" dynamicProvider:^NSColor *(NSAppearance *appearance) {
            NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:@[
                NSAppearanceNameAqua,
                NSAppearanceNameDarkAqua,
            ]];
            if ([match isEqualToString:NSAppearanceNameDarkAqua]) {
                return [NSColor colorWithSRGBRed:0.84 green:0.85 blue:0.87 alpha:1.0];
            }
            return [NSColor colorWithSRGBRed:0.24 green:0.26 blue:0.29 alpha:1.0];
        }];
    });
    return color;
}

static CGFloat APPriorityOpacity(NSString *priority) {
    if ([priority isEqualToString:@"high"]) {
        return 1.00;
    }
    if ([priority isEqualToString:@"low"]) {
        return 0.40;
    }
    return 0.70;
}

static NSColor *APPriorityColor(NSString *priority) {
    return [APTechGrayColor() colorWithAlphaComponent:APPriorityOpacity(priority)];
}

static NSInteger APPositionForItem(NSDictionary *item, NSInteger fallback) {
    id value = item[@"position"];
    if ([value isKindOfClass:NSNumber.class] && [value integerValue] >= 0) {
        return [value integerValue];
    }
    return fallback;
}

static NSArray<NSMutableDictionary *> *APOrderedPendingCopies(NSArray<NSDictionary *> *items) {
    NSMutableArray<NSMutableDictionary *> *ordered = [NSMutableArray array];
    [items enumerateObjectsUsingBlock:^(NSDictionary *item, NSUInteger index, __unused BOOL *stop) {
        NSMutableDictionary *candidate = [item mutableCopy];
        candidate[@"priority"] = APNormalizedPriority(candidate[@"priority"]);
        candidate[@"position"] = @(APPositionForItem(candidate, (NSInteger)index));
        candidate[@"_ap_fallback_index"] = @(index);
        [ordered addObject:candidate];
    }];
    [ordered sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult byPosition = [left[@"position"] compare:right[@"position"]];
        if (byPosition != NSOrderedSame) {
            return byPosition;
        }
        return [left[@"_ap_fallback_index"] compare:right[@"_ap_fallback_index"]];
    }];
    for (NSMutableDictionary *candidate in ordered) {
        [candidate removeObjectForKey:@"_ap_fallback_index"];
    }
    return ordered;
}

static NSString *APPriorityForSegment(NSInteger segment) {
    if (segment == 0) {
        return @"high";
    }
    if (segment == 2) {
        return @"low";
    }
    return @"medium";
}

static NSInteger APSegmentForPriority(NSString *priority) {
    if ([priority isEqualToString:@"high"]) {
        return 0;
    }
    if ([priority isEqualToString:@"low"]) {
        return 2;
    }
    return 1;
}

static NSButton *APIconButton(NSString *symbol, NSString *toolTip, id target, SEL action) {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:toolTip];
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium];
    image = [image imageWithSymbolConfiguration:configuration];
    NSButton *button = [NSButton buttonWithImage:image
                                          target:target
                                          action:action];
    button.bordered = NO;
    button.toolTip = toolTip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:30].active = YES;
    [button.heightAnchor constraintEqualToConstant:30].active = YES;
    return button;
}

static NSButton *APAddButton(NSString *toolTip, id target, SEL action) {
    NSImage *image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:toolTip];
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:24 weight:NSFontWeightSemibold];
    image = [image imageWithSymbolConfiguration:configuration];
    NSButton *button = [NSButton buttonWithImage:image target:target action:action];
    button.bordered = YES;
    button.bezelStyle = NSBezelStyleCircular;
    button.contentTintColor = APTechGrayColor();
    button.toolTip = toolTip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:36].active = YES;
    [button.heightAnchor constraintEqualToConstant:36].active = YES;
    return button;
}

static NSTextField *APEditorField(NSString *value, NSString *placeholder) {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 32)];
    field.font = [NSFont systemFontOfSize:14];
    field.stringValue = value ?: @"";
    field.placeholderString = placeholder;
    return field;
}

static NSView *APEditorForm(
    NSDictionary *item,
    NSTextField **titleFieldResult,
    NSTextView **noteViewResult,
    NSTextField **workspaceFieldResult,
    NSSegmentedControl **priorityControlResult
) {
    const CGFloat width = 420;
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 310)];

    NSTextField *titleLabel = APLabel(APText(@"title_label"), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    titleLabel.translatesAutoresizingMaskIntoConstraints = YES;
    titleLabel.frame = NSMakeRect(0, 289, width, 18);
    NSTextField *titleField = APEditorField(item[@"title"], APText(@"item_placeholder"));
    titleField.frame = NSMakeRect(0, 252, width, 32);

    NSTextField *priorityLabel = APLabel(APText(@"priority_label"), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    priorityLabel.translatesAutoresizingMaskIntoConstraints = YES;
    priorityLabel.frame = NSMakeRect(0, 226, width, 18);
    NSSegmentedControl *priorityControl = [NSSegmentedControl segmentedControlWithLabels:@[
        APText(@"priority_high"), APText(@"priority_medium"), APText(@"priority_low")
    ] trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
    priorityControl.frame = NSMakeRect(0, 190, width, 32);
    priorityControl.selectedSegment = APSegmentForPriority(APNormalizedPriority(item[@"priority"]));
    priorityControl.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];

    NSTextField *noteLabel = APLabel(APText(@"note_label"), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    noteLabel.translatesAutoresizingMaskIntoConstraints = YES;
    noteLabel.frame = NSMakeRect(0, 164, width, 18);
    NSScrollView *noteScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 74, width, 84)];
    noteScroll.borderType = NSBezelBorder;
    noteScroll.hasVerticalScroller = YES;
    noteScroll.autohidesScrollers = YES;
    noteScroll.drawsBackground = YES;
    NSTextView *noteView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, width, 84)];
    noteView.font = [NSFont systemFontOfSize:14];
    noteView.string = item[@"note"] ?: @"";
    noteView.textContainerInset = NSMakeSize(5, 5);
    noteView.minSize = NSMakeSize(0, 84);
    noteView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    noteView.verticallyResizable = YES;
    noteView.horizontallyResizable = NO;
    noteView.autoresizingMask = NSViewWidthSizable;
    noteView.textContainer.widthTracksTextView = YES;
    noteScroll.documentView = noteView;

    NSTextField *workspaceLabel = APLabel(APText(@"workspace_label"), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    workspaceLabel.translatesAutoresizingMaskIntoConstraints = YES;
    workspaceLabel.frame = NSMakeRect(0, 47, width, 18);
    NSString *workspace = item[@"workspace_path"] ?: NSHomeDirectory();
    NSTextField *workspaceField = APEditorField(workspace, APText(@"workspace_placeholder"));
    workspaceField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    workspaceField.frame = NSMakeRect(0, 10, width, 32);

    [form addSubview:titleLabel];
    [form addSubview:titleField];
    [form addSubview:priorityLabel];
    [form addSubview:priorityControl];
    [form addSubview:noteLabel];
    [form addSubview:noteScroll];
    [form addSubview:workspaceLabel];
    [form addSubview:workspaceField];
    *titleFieldResult = titleField;
    *noteViewResult = noteView;
    *workspaceFieldResult = workspaceField;
    *priorityControlResult = priorityControl;
    return form;
}

static NSString *APNormalizedWorkspace(NSString *value) {
    NSString *workspace = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (workspace.length == 0) {
        workspace = NSHomeDirectory();
    }
    workspace = workspace.stringByExpandingTildeInPath.stringByStandardizingPath;
    if (![workspace hasPrefix:@"/"]) {
        workspace = [NSHomeDirectory() stringByAppendingPathComponent:workspace];
    }
    return workspace;
}

@implementation PendingViewController

- (instancetype)initWithDelegate:(id<PendingControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _delegate = delegate;
        _items = @[];
        _contentWidth = APPreferredPopoverWidth(NSScreen.mainScreen);
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, self.contentWidth, 270)];
    self.view = root;

    NSTextField *title = APLabel(APText(@"title"), [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold], NSColor.labelColor);
    self.countLabel = APLabel(APCountText(0), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    self.countLabel.alignment = NSTextAlignmentCenter;
    self.countLabel.drawsBackground = YES;
    self.countLabel.backgroundColor = [NSColor.controlBackgroundColor colorWithAlphaComponent:0.82];
    self.countLabel.textColor = NSColor.secondaryLabelColor;
    self.countLabel.wantsLayer = YES;
    self.countLabel.layer.cornerRadius = 8;
    [self.countLabel.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.countLabel.heightAnchor constraintEqualToConstant:20].active = YES;
    NSStackView *headerText = [NSStackView stackViewWithViews:@[title, self.countLabel]];
    headerText.orientation = NSUserInterfaceLayoutOrientationVertical;
    headerText.alignment = NSLayoutAttributeLeading;
    headerText.spacing = 2;
    headerText.translatesAutoresizingMaskIntoConstraints = NO;

    NSVisualEffectView *header = [[NSVisualEffectView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.material = NSVisualEffectMaterialHeaderView;
    header.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    header.state = NSVisualEffectStateFollowsWindowActiveState;
    NSButton *addButton = APAddButton(APText(@"add"), self, @selector(addClicked:));
    [header addSubview:headerText];
    [header addSubview:addButton];
    [NSLayoutConstraint activateConstraints:@[
        [headerText.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:18],
        [headerText.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [addButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-18],
        [addButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [header.heightAnchor constraintEqualToConstant:64],
    ]];

    self.tableView = [[NSTableView alloc] init];
    self.itemColumn = [[NSTableColumn alloc] initWithIdentifier:@"pending-item"];
    self.itemColumn.resizingMask = NSTableColumnAutoresizingMask;
    self.itemColumn.width = self.contentWidth;
    [self.tableView addTableColumn:self.itemColumn];
    self.tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    self.tableView.headerView = nil;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 108;
    self.tableView.intercellSpacing = NSMakeSize(0, 0);
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    self.tableView.backgroundColor = NSColor.clearColor;
    self.tableView.gridStyleMask = NSTableViewGridNone;
    [self.tableView registerForDraggedTypes:@[APPendingRowPasteboardType]];
    [self.tableView setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];

    NSMenu *rowMenu = [[NSMenu alloc] initWithTitle:@""];
    rowMenu.delegate = self;
    for (NSDictionary *definition in @[
        @{@"title": APText(@"move_top"), @"action": NSStringFromSelector(@selector(moveTopClicked:))},
        @{@"title": APText(@"move_up"), @"action": NSStringFromSelector(@selector(moveUpClicked:))},
        @{@"title": APText(@"move_down"), @"action": NSStringFromSelector(@selector(moveDownClicked:))},
    ]) {
        NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:definition[@"title"]
                                                        action:NSSelectorFromString(definition[@"action"])
                                                 keyEquivalent:@""];
        menuItem.target = self;
        [rowMenu addItem:menuItem];
    }
    self.tableView.menu = rowMenu;

    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.drawsBackground = YES;
    self.scrollView.backgroundColor = NSColor.windowBackgroundColor;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.documentView = self.tableView;

    self.emptyLabel = APLabel(APText(@"empty"), [NSFont systemFontOfSize:14 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    self.emptyLabel.hidden = NO;

    NSTextField *footerText = APLabel(APText(@"footer"), [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor);
    NSButton *quitButton = [NSButton buttonWithTitle:APText(@"quit") target:self action:@selector(quitClicked:)];
    quitButton.bordered = NO;
    quitButton.font = [NSFont systemFontOfSize:12];
    quitButton.contentTintColor = NSColor.secondaryLabelColor;
    quitButton.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *footer = [[NSView alloc] init];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:footerText];
    [footer addSubview:quitButton];
    [NSLayoutConstraint activateConstraints:@[
        [footer.heightAnchor constraintEqualToConstant:46],
        [footerText.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:18],
        [footerText.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [quitButton.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-18],
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
    [root addSubview:self.emptyLabel];
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
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.scrollView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.scrollView.centerYAnchor],
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
    NSArray<NSDictionary *> *latest = items ?: @[];
    BOOL changed = ![self.items isEqualToArray:latest];
    self.items = latest;
    if (!self.isViewLoaded) {
        return;
    }
    self.countLabel.stringValue = APCountText(self.items.count);
    self.emptyLabel.hidden = self.items.count != 0;
    if (changed) {
        [self.tableView reloadData];
    }

    CGFloat height = self.items.count == 0 ? 270 : MIN(680, 128 + self.items.count * 108);
    self.preferredContentSize = NSMakeSize(self.contentWidth, height);
}

- (void)updateContentWidthForScreen:(NSScreen *)screen {
    CGFloat width = APPreferredPopoverWidth(screen);
    if (fabs(width - self.contentWidth) < 0.5) {
        return;
    }
    self.contentWidth = width;
    if (!self.isViewLoaded) {
        return;
    }
    self.itemColumn.width = width;
    CGFloat height = self.items.count == 0 ? 270 : MIN(680, 128 + self.items.count * 108);
    self.preferredContentSize = NSMakeSize(width, height);
}

- (NSView *)rowForItem:(NSDictionary *)item {
    NSView *container = [[NSView alloc] init];
    NSBox *row = [[NSBox alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.toolTip = item[@"workspace_path"] ?: @"";
    row.boxType = NSBoxCustom;
    row.titlePosition = NSNoTitle;
    row.cornerRadius = 10;
    row.borderWidth = 0.5;
    row.borderColor = NSColor.separatorColor;
    row.fillColor = NSColor.controlBackgroundColor;
    row.wantsLayer = YES;
    row.layer.masksToBounds = NO;
    row.layer.shadowColor = NSColor.blackColor.CGColor;
    row.layer.shadowOpacity = 0.2;
    row.layer.shadowRadius = 8;
    row.layer.shadowOffset = NSMakeSize(0, -3);

    NSBox *accent = [[NSBox alloc] init];
    accent.translatesAutoresizingMaskIntoConstraints = NO;
    accent.boxType = NSBoxCustom;
    accent.titlePosition = NSNoTitle;
    accent.cornerRadius = 1.5;
    accent.borderWidth = 0;
    NSString *priority = APNormalizedPriority(item[@"priority"]);
    NSColor *priorityColor = APPriorityColor(priority);
    accent.fillColor = priorityColor;

    NSImage *dragImage = [NSImage imageWithSystemSymbolName:@"line.3.horizontal"
                                  accessibilityDescription:APText(@"drag_reorder")];
    NSImageSymbolConfiguration *dragConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium];
    dragImage = [dragImage imageWithSymbolConfiguration:dragConfiguration];
    NSImageView *dragHandle = [[NSImageView alloc] initWithFrame:NSZeroRect];
    dragHandle.image = dragImage;
    dragHandle.translatesAutoresizingMaskIntoConstraints = NO;
    dragHandle.contentTintColor = priorityColor;
    dragHandle.toolTip = APText(@"drag_reorder");

    NSTextField *title = APLabel(item[@"title"] ?: @"", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.maximumNumberOfLines = 1;

    NSTextField *subtitle = APLabel(item[@"note"] ?: @"", [NSFont systemFontOfSize:13], NSColor.secondaryLabelColor);
    subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    subtitle.maximumNumberOfLines = 1;

    NSString *workspace = [item[@"workspace_path"] lastPathComponent];
    if (workspace.length == 0) {
        workspace = item[@"workspace_path"] ?: @"";
    }
    NSString *metadataText = [NSString stringWithFormat:@"%@  ·  %@",
                              workspace,
                              [self displayDate:item[@"created_at"]]];
    NSTextField *metadata = APLabel(metadataText, [NSFont systemFontOfSize:11], NSColor.tertiaryLabelColor);
    metadata.lineBreakMode = NSLineBreakByTruncatingMiddle;
    metadata.maximumNumberOfLines = 1;

    NSStackView *textStack = [NSStackView stackViewWithViews:@[title, subtitle, metadata]];
    textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    textStack.alignment = NSLayoutAttributeLeading;
    textStack.spacing = 3;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSString *identifier = item[@"id"] ?: @"";
    NSButton *copy = APIconButton(@"doc.on.doc", APText(@"copy_workspace"), self, @selector(copyWorkspaceClicked:));
    copy.identifier = identifier;
    copy.contentTintColor = priorityColor;
    NSButton *edit = APIconButton(@"pencil", APText(@"edit"), self, @selector(editClicked:));
    edit.identifier = identifier;
    edit.contentTintColor = priorityColor;
    NSButton *complete = APIconButton(@"checkmark.circle.fill", APText(@"complete"), self, @selector(completeClicked:));
    complete.identifier = identifier;
    complete.contentTintColor = priorityColor;

    [container addSubview:row];
    [row addSubview:dragHandle];
    [row addSubview:accent];
    [row addSubview:textStack];
    [row addSubview:copy];
    [row addSubview:edit];
    [row addSubview:complete];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:14],
        [row.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-28],
        [row.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [row.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [row.heightAnchor constraintEqualToConstant:96],
        [dragHandle.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:9],
        [dragHandle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [dragHandle.widthAnchor constraintEqualToConstant:14],
        [accent.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:29],
        [accent.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [accent.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
        [accent.widthAnchor constraintEqualToConstant:3],
        [textStack.leadingAnchor constraintEqualToAnchor:accent.trailingAnchor constant:14],
        [textStack.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [copy.leadingAnchor constraintGreaterThanOrEqualToAnchor:textStack.trailingAnchor constant:8],
        [copy.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [edit.leadingAnchor constraintEqualToAnchor:copy.trailingAnchor constant:6],
        [edit.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [complete.leadingAnchor constraintEqualToAnchor:edit.trailingAnchor constant:6],
        [complete.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [complete.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return container;
}

- (NSInteger)numberOfRowsInTableView:(__unused NSTableView *)tableView {
    return (NSInteger)self.items.count;
}

- (NSView *)tableView:(__unused NSTableView *)tableView
   viewForTableColumn:(__unused NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.items.count) {
        return nil;
    }
    return [self rowForItem:self.items[(NSUInteger)row]];
}

- (id<NSPasteboardWriting>)tableView:(__unused NSTableView *)tableView
              pasteboardWriterForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.items.count) {
        return nil;
    }
    NSPasteboardItem *pasteboardItem = [[NSPasteboardItem alloc] init];
    [pasteboardItem setString:self.items[(NSUInteger)row][@"id"] ?: @""
                      forType:APPendingRowPasteboardType];
    return pasteboardItem;
}

- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(__unused NSTableViewDropOperation)dropOperation {
    NSString *identifier = [info.draggingPasteboard stringForType:APPendingRowPasteboardType];
    if (identifier.length == 0 || info.draggingSource != tableView) {
        return NSDragOperationNone;
    }
    [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    return NSDragOperationMove;
}

- (BOOL)tableView:(__unused NSTableView *)tableView
        acceptDrop:(id<NSDraggingInfo>)info
               row:(NSInteger)row
     dropOperation:(__unused NSTableViewDropOperation)dropOperation {
    NSString *identifier = [info.draggingPasteboard stringForType:APPendingRowPasteboardType];
    NSInteger source = [self.items indexOfObjectPassingTest:^BOOL(
        NSDictionary *candidate,
        __unused NSUInteger index,
        __unused BOOL *stop
    ) {
        return [candidate[@"id"] isEqualToString:identifier];
    }];
    if (source == NSNotFound) {
        return NO;
    }
    NSInteger destination = row;
    if (source < destination) {
        destination -= 1;
    }
    destination = MAX(0, MIN(destination, (NSInteger)self.items.count - 1));
    return [self moveItemFromIndex:source toIndex:destination];
}

- (BOOL)moveItemFromIndex:(NSInteger)source toIndex:(NSInteger)destination {
    if (source < 0 || source >= (NSInteger)self.items.count ||
        destination < 0 || destination >= (NSInteger)self.items.count ||
        source == destination) {
        return source == destination;
    }
    NSMutableArray<NSDictionary *> *reordered = [self.items mutableCopy];
    NSDictionary *item = reordered[(NSUInteger)source];
    [reordered removeObjectAtIndex:(NSUInteger)source];
    [reordered insertObject:item atIndex:(NSUInteger)destination];
    self.items = [reordered copy];
    [self.tableView reloadData];

    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:self.items.count];
    for (NSDictionary *candidate in self.items) {
        NSString *identifier = candidate[@"id"];
        if (identifier.length > 0) {
            [identifiers addObject:identifier];
        }
    }
    [self.delegate reorderItemsWithIdentifiers:identifiers];
    return YES;
}

- (NSInteger)contextRow {
    NSInteger row = self.tableView.clickedRow;
    return row >= 0 ? row : self.tableView.selectedRow;
}

- (void)menuWillOpen:(NSMenu *)menu {
    NSInteger row = [self contextRow];
    BOOL valid = row >= 0 && row < (NSInteger)self.items.count;
    if (menu.numberOfItems >= 3) {
        [menu itemAtIndex:0].enabled = valid && row > 0;
        [menu itemAtIndex:1].enabled = valid && row > 0;
        [menu itemAtIndex:2].enabled = valid && row < (NSInteger)self.items.count - 1;
    }
}

- (void)moveTopClicked:(__unused id)sender {
    [self moveItemFromIndex:[self contextRow] toIndex:0];
}

- (void)moveUpClicked:(__unused id)sender {
    NSInteger row = [self contextRow];
    [self moveItemFromIndex:row toIndex:row - 1];
}

- (void)moveDownClicked:(__unused id)sender {
    NSInteger row = [self contextRow];
    [self moveItemFromIndex:row toIndex:row + 1];
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
    BOOL english = [APLanguage() isEqualToString:@"en"];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:(english ? @"en_US_POSIX" : @"zh_CN")];
    formatter.dateFormat = english ? @"MMM d, HH:mm" : @"M月d日 HH:mm";
    return [formatter stringFromDate:date];
}

- (void)editClicked:(NSButton *)sender {
    [self.delegate editItemWithIdentifier:sender.identifier];
}

- (void)copyWorkspaceClicked:(NSButton *)sender {
    NSString *workspace = nil;
    NSColor *priorityColor = APTechGrayColor();
    for (NSDictionary *item in self.items) {
        if ([item[@"id"] isEqualToString:sender.identifier]) {
            workspace = item[@"workspace_path"];
            priorityColor = APPriorityColor(APNormalizedPriority(item[@"priority"]));
            break;
        }
    }
    if (workspace.length == 0) {
        NSBeep();
        return;
    }
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    if (![pasteboard setString:workspace forType:NSPasteboardTypeString]) {
        NSBeep();
        return;
    }
    sender.image = [NSImage imageWithSystemSymbolName:@"checkmark" accessibilityDescription:APText(@"workspace_copied")];
    sender.toolTip = APText(@"workspace_copied");
    sender.contentTintColor = priorityColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sender.image = [NSImage imageWithSystemSymbolName:@"doc.on.doc" accessibilityDescription:APText(@"copy_workspace")];
        sender.toolTip = APText(@"copy_workspace");
        sender.contentTintColor = priorityColor;
    });
}

- (void)addClicked:(id)sender {
    [self.delegate addItem];
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

    [self rebuildLocalizedInterface];

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.image = [NSImage imageWithSystemSymbolName:@"tray.full" accessibilityDescription:@"Agent Pending"];
    button.target = self;
    button.action = @selector(statusItemClicked:);
    [button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    [self refreshAndNotify:NO];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(refreshTimerFired:)
                                                      userInfo:nil
                                                       repeats:YES];

    if ([NSProcessInfo.processInfo.environment[@"AGENT_PENDING_SCREENSHOT_MODE"] isEqualToString:@"1"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showScreenshotPopover];
        });
    } else if ([NSProcessInfo.processInfo.environment[@"AGENT_PENDING_OPEN_ON_LAUNCH"] isEqualToString:@"1"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showListFromMenu:nil];
        });
    }
}

- (void)showScreenshotPopover {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (!screen) {
        [self showListFromMenu:nil];
        return;
    }

    [self.pendingController updateContentWidthForScreen:screen];
    (void)self.pendingController.view;
    [self.pendingController updateItems:self.items];
    NSSize popoverSize = self.pendingController.preferredContentSize;
    NSRect visibleFrame = screen.visibleFrame;
    NSRect anchorFrame = NSMakeRect(
        NSMidX(visibleFrame) - 1,
        NSMidY(visibleFrame) + popoverSize.height / 2,
        2,
        2
    );
    self.screenshotAnchorWindow = [[NSWindow alloc]
        initWithContentRect:anchorFrame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO
                     screen:screen];
    self.screenshotAnchorWindow.opaque = NO;
    self.screenshotAnchorWindow.backgroundColor = NSColor.clearColor;
    self.screenshotAnchorWindow.ignoresMouseEvents = YES;
    [self.screenshotAnchorWindow orderFront:nil];

    [self.popover showRelativeToRect:self.screenshotAnchorWindow.contentView.bounds
                              ofView:self.screenshotAnchorWindow.contentView
                       preferredEdge:NSRectEdgeMinY];
}

- (void)rebuildLocalizedInterface {
    BOOL wasShown = self.popover.shown;
    [self.popover performClose:nil];

    self.pendingController = [[PendingViewController alloc] initWithDelegate:self];
    self.popover = [[NSPopover alloc] init];
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.contentViewController = self.pendingController;
    self.popover.contentSize = NSMakeSize(420, 270);
    [self.pendingController updateItems:self.items];

    self.statusMenu = [[NSMenu alloc] initWithTitle:@"Agent Pending"];
    NSMenuItem *showItem = [[NSMenuItem alloc] initWithTitle:APText(@"show_list")
                                                     action:@selector(showListFromMenu:)
                                              keyEquivalent:@""];
    showItem.target = self;
    [self.statusMenu addItem:showItem];

    NSMenu *languageMenu = [[NSMenu alloc] initWithTitle:APText(@"language")];
    for (NSArray<NSString *> *choice in @[@[@"zh", @"中文"], @[@"en", @"English"]]) {
        NSMenuItem *languageItem = [[NSMenuItem alloc] initWithTitle:choice[1]
                                                             action:@selector(changeLanguage:)
                                                      keyEquivalent:@""];
        languageItem.target = self;
        languageItem.representedObject = choice[0];
        languageItem.state = [APLanguage() isEqualToString:choice[0]] ? NSControlStateValueOn : NSControlStateValueOff;
        [languageMenu addItem:languageItem];
    }
    NSMenuItem *languageRoot = [[NSMenuItem alloc] initWithTitle:APText(@"language") action:nil keyEquivalent:@""];
    languageRoot.submenu = languageMenu;
    [self.statusMenu addItem:languageRoot];
    [self.statusMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *restartItem = [[NSMenuItem alloc] initWithTitle:APText(@"restart")
                                                        action:@selector(restartApplication:)
                                                 keyEquivalent:@""];
    restartItem.target = self;
    [self.statusMenu addItem:restartItem];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:APText(@"quit_app")
                                                     action:@selector(quitApplicationFromMenu:)
                                              keyEquivalent:@""];
    quitItem.target = self;
    [self.statusMenu addItem:quitItem];

    if (wasShown && self.statusItem.button) {
        [self showListFromMenu:nil];
    }
}

- (void)changeLanguage:(NSMenuItem *)sender {
    NSString *language = sender.representedObject;
    if (![language isEqualToString:@"zh"] && ![language isEqualToString:@"en"]) {
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:language forKey:@"AgentPendingLanguage"];
    [self rebuildLocalizedInterface];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"Agent Pending terminating");
    [self.refreshTimer invalidate];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    if (![NSProcessInfo.processInfo.environment[@"AGENT_PENDING_SCREENSHOT_MODE"] isEqualToString:@"1"] &&
        self.popover.shown) {
        [self.popover performClose:nil];
    }
}

- (void)statusItemClicked:(NSStatusBarButton *)sender {
    NSEvent *event = NSApp.currentEvent;
    NSLog(@"Agent Pending status item click: type=%ld", (long)event.type);
    if (event.type == NSEventTypeRightMouseUp) {
        [self.popover performClose:nil];
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
    NSScreen *screen = self.statusItem.button.window.screen ?: NSScreen.mainScreen;
    [self.pendingController updateContentWidthForScreen:screen];
    [self.pendingController updateItems:self.items];
    [NSApp activateIgnoringOtherApps:YES];
    [self.popover showRelativeToRect:self.statusItem.button.bounds
                              ofView:self.statusItem.button
                       preferredEdge:NSRectEdgeMinY];
}

- (void)showListFromMenu:(id)sender {
    if (!self.popover.shown) {
        NSScreen *screen = self.statusItem.button.window.screen ?: NSScreen.mainScreen;
        [self.pendingController updateContentWidthForScreen:screen];
        [self.pendingController updateItems:self.items];
        [NSApp activateIgnoringOtherApps:YES];
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
    content.title = item[@"title"] ?: APText(@"new_item");
    content.body = item[@"note"] ?: @"";
    content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:item[@"id"] ?: NSUUID.UUID.UUIDString
                                                                          content:content
                                                                          trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

- (void)addItem {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = APText(@"add_item");
    [alert addButtonWithTitle:APText(@"add")];
    [alert addButtonWithTitle:APText(@"cancel")];

    NSTextField *titleField = nil;
    NSTextView *noteView = nil;
    NSTextField *workspaceField = nil;
    NSSegmentedControl *priorityControl = nil;
    alert.accessoryView = APEditorForm(nil, &titleField, &noteView, &workspaceField, &priorityControl);
    alert.window.initialFirstResponder = titleField;

    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    NSString *title = [titleField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *note = [noteView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (title.length == 0 || note.length == 0) {
        NSBeep();
        return;
    }
    NSString *workspace = APNormalizedWorkspace(workspaceField.stringValue);
    NSString *priority = APPriorityForSegment(priorityControl.selectedSegment);
    NSInteger nextPosition = 0;
    for (NSDictionary *candidate in self.items) {
        nextPosition = MAX(nextPosition, APPositionForItem(candidate, nextPosition) + 1);
    }

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSMutableDictionary *newItem = [@{
        @"id": NSUUID.UUID.UUIDString,
        @"title": title,
        @"note": note,
        @"workspace_path": workspace,
        @"created_at": [formatter stringFromDate:NSDate.date],
        @"priority": priority,
        @"position": @(nextPosition),
    } mutableCopy];
    [self modifyItems:^(NSMutableArray<NSMutableDictionary *> *items) {
        for (NSDictionary *candidate in items) {
            if ([candidate[@"title"] isEqualToString:title] &&
                [candidate[@"note"] isEqualToString:note] &&
                [candidate[@"workspace_path"] isEqualToString:workspace]) {
                return;
            }
        }
        [items addObject:newItem];
    }];
}

- (void)editItemWithIdentifier:(NSString *)identifier {
    NSDictionary *item = [self itemWithIdentifier:identifier];
    if (!item) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = APText(@"edit_item");
    [alert addButtonWithTitle:APText(@"save")];
    [alert addButtonWithTitle:APText(@"cancel")];

    NSTextField *titleField = nil;
    NSTextView *noteView = nil;
    NSTextField *workspaceField = nil;
    NSSegmentedControl *priorityControl = nil;
    alert.accessoryView = APEditorForm(item, &titleField, &noteView, &workspaceField, &priorityControl);
    alert.window.initialFirstResponder = titleField;

    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    NSString *title = [titleField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *note = [noteView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *workspace = APNormalizedWorkspace(workspaceField.stringValue);
    NSString *priority = APPriorityForSegment(priorityControl.selectedSegment);
    if (title.length == 0 || note.length == 0) {
        return;
    }

    [self modifyItems:^(NSMutableArray<NSMutableDictionary *> *items) {
        for (NSMutableDictionary *candidate in items) {
            if ([candidate[@"id"] isEqualToString:identifier]) {
                candidate[@"title"] = title;
                candidate[@"note"] = note;
                candidate[@"workspace_path"] = workspace;
                candidate[@"priority"] = priority;
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
        NSMutableArray<NSMutableDictionary *> *pending = [APOrderedPendingCopies(store[@"pending"]) mutableCopy];
        store[@"pending"] = pending;
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
        [pending enumerateObjectsUsingBlock:^(NSMutableDictionary *candidate, NSUInteger position, __unused BOOL *stop) {
            candidate[@"position"] = @(position);
        }];
        [store[@"archive"] addObject:item];
        return [self writeStore:store error:error];
    } error:nil];
    [self refreshAndNotify:NO];
}

- (void)reorderItemsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    [self withExclusiveLock:^BOOL(NSError **error) {
        NSMutableDictionary *store = [self mutableStoreFromDisk:error];
        if (!store) {
            return NO;
        }
        NSArray<NSMutableDictionary *> *current = APOrderedPendingCopies(store[@"pending"]);
        NSMutableDictionary<NSString *, NSMutableDictionary *> *byIdentifier = [NSMutableDictionary dictionary];
        for (NSMutableDictionary *item in current) {
            NSString *identifier = item[@"id"];
            if (identifier.length > 0) {
                byIdentifier[identifier] = item;
            }
        }

        NSMutableArray<NSMutableDictionary *> *reordered = [NSMutableArray arrayWithCapacity:current.count];
        NSMutableSet<NSString *> *included = [NSMutableSet set];
        for (NSString *identifier in identifiers) {
            NSMutableDictionary *item = byIdentifier[identifier];
            if (item && ![included containsObject:identifier]) {
                [reordered addObject:item];
                [included addObject:identifier];
            }
        }
        for (NSMutableDictionary *item in current) {
            NSString *identifier = item[@"id"];
            if (identifier.length == 0 || ![included containsObject:identifier]) {
                [reordered addObject:item];
            }
        }
        [reordered enumerateObjectsUsingBlock:^(NSMutableDictionary *item, NSUInteger position, __unused BOOL *stop) {
            item[@"position"] = @(position);
            item[@"priority"] = APNormalizedPriority(item[@"priority"]);
        }];
        store[@"pending"] = reordered;
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
        result = [APOrderedPendingCopies(store[@"pending"]) copy];
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
