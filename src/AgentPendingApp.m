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
            @"footer": @{@"zh": @"点击 + 新增，或调用 $agent-pending", @"en": @"Use + or $agent-pending to add"},
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
    button.contentTintColor = NSColor.systemIndigoColor;
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
    NSTextField **workspaceFieldResult
) {
    const CGFloat width = 420;
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 246)];

    NSTextField *titleLabel = APLabel(APText(@"title_label"), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    titleLabel.translatesAutoresizingMaskIntoConstraints = YES;
    titleLabel.frame = NSMakeRect(0, 225, width, 18);
    NSTextField *titleField = APEditorField(item[@"title"], APText(@"item_placeholder"));
    titleField.frame = NSMakeRect(0, 188, width, 32);

    NSTextField *noteLabel = APLabel(APText(@"note_label"), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    noteLabel.translatesAutoresizingMaskIntoConstraints = YES;
    noteLabel.frame = NSMakeRect(0, 162, width, 18);
    NSScrollView *noteScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 72, width, 84)];
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
    workspaceLabel.frame = NSMakeRect(0, 45, width, 18);
    NSString *workspace = item[@"workspace_path"] ?: NSHomeDirectory();
    NSTextField *workspaceField = APEditorField(workspace, APText(@"workspace_placeholder"));
    workspaceField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    workspaceField.frame = NSMakeRect(0, 8, width, 32);

    [form addSubview:titleLabel];
    [form addSubview:titleField];
    [form addSubview:noteLabel];
    [form addSubview:noteScroll];
    [form addSubview:workspaceLabel];
    [form addSubview:workspaceField];
    *titleFieldResult = titleField;
    *noteViewResult = noteView;
    *workspaceFieldResult = workspaceField;
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
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 270)];
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

    self.itemStack = [[NSStackView alloc] init];
    self.itemStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.itemStack.alignment = NSLayoutAttributeLeading;
    self.itemStack.spacing = 12;
    self.itemStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *documentView = [[NSView alloc] init];
    documentView.translatesAutoresizingMaskIntoConstraints = NO;
    [documentView addSubview:self.itemStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.itemStack.topAnchor constraintEqualToAnchor:documentView.topAnchor constant:14],
        [self.itemStack.leadingAnchor constraintEqualToAnchor:documentView.leadingAnchor constant:14],
        [self.itemStack.trailingAnchor constraintEqualToAnchor:documentView.trailingAnchor constant:-14],
        [self.itemStack.bottomAnchor constraintEqualToAnchor:documentView.bottomAnchor constant:-14],
    ]];

    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.drawsBackground = YES;
    self.scrollView.backgroundColor = NSColor.windowBackgroundColor;
    self.scrollView.documentView = documentView;
    [documentView.widthAnchor constraintEqualToAnchor:self.scrollView.contentView.widthAnchor].active = YES;

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
    self.countLabel.stringValue = APCountText(self.items.count);
    for (NSView *view in [self.itemStack.arrangedSubviews copy]) {
        [self.itemStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (self.items.count == 0) {
        NSView *empty = [[NSView alloc] init];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *emptyLabel = APLabel(APText(@"empty"), [NSFont systemFontOfSize:14 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
        [empty addSubview:emptyLabel];
        [NSLayoutConstraint activateConstraints:@[
            [empty.heightAnchor constraintEqualToConstant:130],
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

    CGFloat height = self.items.count == 0 ? 270 : MIN(680, 128 + self.items.count * 108);
    self.preferredContentSize = NSMakeSize(420, height);
}

- (NSView *)rowForItem:(NSDictionary *)item {
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
    accent.fillColor = NSColor.systemIndigoColor;

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
    copy.contentTintColor = NSColor.systemTealColor;
    NSButton *edit = APIconButton(@"pencil", APText(@"edit"), self, @selector(editClicked:));
    edit.identifier = identifier;
    edit.contentTintColor = NSColor.systemPurpleColor;
    NSButton *complete = APIconButton(@"checkmark.circle.fill", APText(@"complete"), self, @selector(completeClicked:));
    complete.identifier = identifier;
    complete.contentTintColor = NSColor.systemIndigoColor;

    [row addSubview:accent];
    [row addSubview:textStack];
    [row addSubview:copy];
    [row addSubview:edit];
    [row addSubview:complete];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:96],
        [accent.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [accent.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [accent.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
        [accent.widthAnchor constraintEqualToConstant:3],
        [textStack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:18],
        [textStack.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [copy.leadingAnchor constraintGreaterThanOrEqualToAnchor:textStack.trailingAnchor constant:8],
        [copy.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [edit.leadingAnchor constraintEqualToAnchor:copy.trailingAnchor constant:6],
        [edit.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [complete.leadingAnchor constraintEqualToAnchor:edit.trailingAnchor constant:6],
        [complete.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
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
    for (NSDictionary *item in self.items) {
        if ([item[@"id"] isEqualToString:sender.identifier]) {
            workspace = item[@"workspace_path"];
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
    sender.contentTintColor = NSColor.systemTealColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sender.image = [NSImage imageWithSystemSymbolName:@"doc.on.doc" accessibilityDescription:APText(@"copy_workspace")];
        sender.toolTip = APText(@"copy_workspace");
        sender.contentTintColor = NSColor.systemTealColor;
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
    [self.pendingController updateItems:self.items];
    [NSApp activateIgnoringOtherApps:YES];
    [self.popover showRelativeToRect:self.statusItem.button.bounds
                              ofView:self.statusItem.button
                       preferredEdge:NSRectEdgeMinY];
}

- (void)showListFromMenu:(id)sender {
    if (!self.popover.shown) {
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
    alert.accessoryView = APEditorForm(nil, &titleField, &noteView, &workspaceField);
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

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSMutableDictionary *newItem = [@{
        @"id": NSUUID.UUID.UUIDString,
        @"title": title,
        @"note": note,
        @"workspace_path": workspace,
        @"created_at": [formatter stringFromDate:NSDate.date],
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
    alert.accessoryView = APEditorForm(item, &titleField, &noteView, &workspaceField);
    alert.window.initialFirstResponder = titleField;

    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    NSString *title = [titleField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *note = [noteView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *workspace = APNormalizedWorkspace(workspaceField.stringValue);
    if (title.length == 0 || note.length == 0) {
        return;
    }

    [self modifyItems:^(NSMutableArray<NSMutableDictionary *> *items) {
        for (NSMutableDictionary *candidate in items) {
            if ([candidate[@"id"] isEqualToString:identifier]) {
                candidate[@"title"] = title;
                candidate[@"note"] = note;
                candidate[@"workspace_path"] = workspace;
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
