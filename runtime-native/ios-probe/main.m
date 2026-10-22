// Project-owned device harness. Never loads code from the reference IPA.
#import <UIKit/UIKit.h>
#import "MSJavaRuntime.h"
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

// A scene can reconnect while the process and its one-shot JVM still exist.
static NSMutableDictionary *processReport;
static NSURL *processDirectory;
static BOOL processAttempted;
static NSString *const reportChanged = @"MSProbeReportChanged";

static NSString *Text(NSString *key) {
    NSString *language = [[NSUserDefaults standardUserDefaults] stringForKey:@"app.language"] ?: @"en";
    NSString *path = [[NSBundle mainBundle] pathForResource:language ofType:@"lproj"];
    return [[NSBundle bundleWithPath:path] localizedStringForKey:key value:key table:nil] ?: key;
}

@interface MSProbeController : UIViewController
@property(nonatomic, strong) UITextView *reportView;
@property(nonatomic, strong) UILabel *descriptionLabel;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) UIButton *shareButton;
@property(nonatomic, strong) UISegmentedControl *languageControl;
@property(nonatomic, strong) NSMutableDictionary *report;
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic) BOOL attempted;
@end

@implementation MSProbeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    if (!processReport) {
        NSError *error = nil;
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        processDirectory = [documents URLByAppendingPathComponent:@"EngineCheck" isDirectory:YES];
        if (![NSFileManager.defaultManager createDirectoryAtURL:processDirectory withIntermediateDirectories:YES attributes:nil error:&error]) {
            processReport = [@{@"stage": @"storage_failed", @"error": error.localizedDescription ?: @"No writable directory"} mutableCopy];
            processAttempted = YES;
        } else {
            NSURL *path = [processDirectory URLByAppendingPathComponent:@"report.json"];
            NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path.path error:NULL];
            NSData *previous = [attributes fileSize] <= 1024 * 1024 ? [NSData dataWithContentsOfURL:path] : nil;
            NSDictionary *saved = previous ? [NSJSONSerialization JSONObjectWithData:previous options:0 error:NULL] : nil;
            // Preserve the whole last report, especially a VM crash's last saved stage.
            processReport = [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [@{@"stage": @"ready"} mutableCopy];
        }
    }
    self.directory = processDirectory;
    self.report = processReport;
    self.attempted = processAttempted;

    self.languageControl = [[UISegmentedControl alloc] initWithItems:@[@"English", @"العربية"]];
    self.languageControl.selectedSegmentIndex = [[[NSUserDefaults standardUserDefaults] stringForKey:@"app.language"] isEqualToString:@"ar"] ? 1 : 0;
    [self.languageControl addTarget:self action:@selector(changeLanguage) forControlEvents:UIControlEventValueChanged];

    UILabel *description = [[UILabel alloc] init];
    description.numberOfLines = 0;
    description.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    description.adjustsFontForContentSizeCategory = YES;
    description.accessibilityIdentifier = @"probe.description";
    self.descriptionLabel = description;
    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.runButton.configuration = UIButtonConfiguration.filledButtonConfiguration;
    self.runButton.accessibilityIdentifier = @"probe.run";
    self.runButton.enabled = !self.attempted;
    [self.runButton addTarget:self action:@selector(runCheck) forControlEvents:UIControlEventTouchUpInside];
    self.shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.shareButton.configuration = UIButtonConfiguration.borderedButtonConfiguration;
    [self.shareButton addTarget:self action:@selector(shareReport) forControlEvents:UIControlEventTouchUpInside];

    self.reportView = [[UITextView alloc] init];
    self.reportView.editable = NO;
    self.reportView.selectable = YES;
    self.reportView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.reportView.accessibilityIdentifier = @"probe.report";
    self.reportView.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    self.reportView.textAlignment = NSTextAlignmentLeft;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.languageControl, description, self.runButton, self.shareButton, self.reportView]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [self.runButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.shareButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    [self changeLanguage];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshReport) name:reportChanged object:nil];
    [self refreshReport];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)changeLanguage {
    NSString *language = self.languageControl.selectedSegmentIndex == 1 ? @"ar" : @"en";
    [[NSUserDefaults standardUserDefaults] setObject:language forKey:@"app.language"];
    self.navigationItem.title = Text(@"Engine check");
    self.view.semanticContentAttribute = [language isEqualToString:@"ar"] ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    self.descriptionLabel.text = Text(@"Check the source engine on this iPhone. This checks Java startup and a MangaShelf test JAR. It does not enable extensions yet.");
    [self.runButton setTitle:Text(self.attempted ? @"Restart this app to run the check again." : @"Run engine check") forState:UIControlStateNormal];
    [self.shareButton setTitle:Text(@"Share engine report") forState:UIControlStateNormal];
}

- (void)refreshReport {
    self.attempted = processAttempted;
    self.runButton.enabled = !self.attempted;
    [self changeLanguage];
    NSData *json = [NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    self.reportView.text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"Report serialization failed";
}

- (BOOL)saveReport {
    NSData *json = [NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    NSError *error = nil;
    BOOL saved = json && [json writeToURL:[self.directory URLByAppendingPathComponent:@"report.json"] options:NSDataWritingAtomic error:&error];
    if (!saved) self.report[@"report_write_error"] = error.localizedDescription ?: @"Report serialization failed";
    [NSNotificationCenter.defaultCenter postNotificationName:reportChanged object:nil];
    return saved;
}

- (void)runCheck {
    if (processAttempted) return;
    processAttempted = YES;
    NSData *previous = [NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted error:NULL];
    NSError *error = nil;
    if (!previous || ![previous writeToURL:[self.directory URLByAppendingPathComponent:@"previous-report.json"] options:NSDataWritingAtomic error:&error]) {
        self.report[@"archive_error"] = error.localizedDescription ?: @"Could not preserve the previous report";
        [self refreshReport];
        return;
    }
    [self.report removeAllObjects];
    [self.report addEntriesFromDictionary:@{
        @"stage": @"starting_vm", @"scope": @"VM and project-owned JAR check; does not test a real extension",
        @"ios": UIDevice.currentDevice.systemVersion,
        @"build": [NSBundle.mainBundle objectForInfoDictionaryKey:@"MSBuildCommit"] ?: @"unknown",
        @"runtime_run_id": [NSBundle.mainBundle objectForInfoDictionaryKey:@"MSRuntimeRunID"] ?: @"unknown",
        @"probe_version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
    }];
    if (![self saveReport]) return;
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            [self runOnWorker];
        }
    }];
    worker.name = @"MangaShelf JVM check";
    worker.stackSize = 8 * 1024 * 1024;
    [worker start];
}

- (void)runOnWorker {
    // Persist logs before native startup, including if the VM terminates this process.
    NSString *log = [[self.directory URLByAppendingPathComponent:@"runtime.log"] path];
    if (chdir(self.directory.path.fileSystemRepresentation) != 0) {
        [self recordSetupFailure:errno];
        return;
    }
    int descriptor = open(log.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0600);
    if (descriptor < 0) {
        [self recordSetupFailure:errno];
        return;
    }
    if (dup2(descriptor, STDERR_FILENO) < 0 || dup2(descriptor, STDOUT_FILENO) < 0) {
        int failure = errno;
        close(descriptor);
        [self recordSetupFailure:failure];
        return;
    }
    close(descriptor);
    setvbuf(stderr, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *classpath = [resources stringByAppendingPathComponent:@"probe/main.jar"];
    // Match the pinned static iOS VM's home before it parses Java options.
    NSString *home = [resources stringByAppendingPathComponent:@"lib"];
    NSString *plugin = [resources stringByAppendingPathComponent:@"probe/plugin.jar"];
    int start = ms_java_start(JNI_CreateJavaVM, classpath.fileSystemRepresentation, home.fileSystemRepresentation);
    NSMutableDictionary *result = [@{@"start_code": @(start)} mutableCopy];
    if (start == MS_JAVA_OK) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            self.report[@"stage"] = @"reading_java_properties";
            self.report[@"start_code"] = @(start);
            [self saveReport];
        });
        char output[8192];
        size_t needed = 0;
        int diagnostics = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "diagnostics", "", "",
                                               output, sizeof(output), &needed);
        NSString *properties = diagnostics == MS_JAVA_OK ? [NSString stringWithUTF8String:output] : nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            self.report[@"java_diagnostics_code"] = @(diagnostics);
            if (properties) self.report[@"java_diagnostics"] = properties;
            self.report[@"stage"] = @"loading_project_jar";
            [self saveReport];
        });
        int call = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "runWithDiagnostics", plugin.fileSystemRepresentation,
                                       self.directory.path.fileSystemRepresentation, output, sizeof(output), &needed);
        result[@"call_code"] = @(call);
        result[@"stage"] = @"java_check_failed";
        if (call == MS_JAVA_OK) {
            result[@"output"] = [NSString stringWithUTF8String:output] ?: @"Invalid UTF-8";
            int unicode = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "echo", "مانغا ", "📚",
                                              output, sizeof(output), &needed);
            NSString *echo = unicode == MS_JAVA_OK ? [NSString stringWithUTF8String:output] : nil;
            BOOL matched = [echo isEqualToString:@"مانغا 📚"];
            result[@"unicode_code"] = @(unicode);
            result[@"unicode_roundtrip"] = @(matched);
            result[@"stage"] = matched ? @"passed" : @"unicode_check_failed";
        }
    } else {
        result[@"stage"] = @"vm_start_failed";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.report addEntriesFromDictionary:result];
        [self saveReport];
    });
}

- (void)recordSetupFailure:(int)code {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.report[@"stage"] = @"diagnostics_setup_failed";
        self.report[@"error"] = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil].localizedDescription;
        [self saveReport];
    });
}

- (void)shareReport {
    NSMutableArray *items = [NSMutableArray arrayWithObject:self.reportView.text ?: @""];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:nil options:0 error:NULL];
    for (NSURL *file in files) {
        if ([@[@"json", @"log"] containsObject:file.pathExtension] && items.count < 10) [items addObject:file];
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.shareButton;
    share.popoverPresentationController.sourceRect = self.shareButton.bounds;
    [self presentViewController:share animated:YES completion:nil];
}
@end

@interface MSProbeScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation MSProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[[MSProbeController alloc] init]];
    [self.window makeKeyAndVisible];
}
@end

@interface MSProbeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation MSProbeDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)application; (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"EngineCheck" sessionRole:session.role];
    configuration.delegateClass = MSProbeScene.class;
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(MSProbeDelegate.class));
    }
}
