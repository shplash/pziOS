// pziOS host: boots the bundled iOS OpenJDK in-process via libjli's JLI_Launch.
// The JVM can only be created once per process, so each run needs an app relaunch.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <dlfcn.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <sys/sysctl.h>
#import <os/proc.h>
#import <mach/mach.h>
#import <mach/vm_statistics.h>
#import <malloc/malloc.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <stdatomic.h>
#ifdef ZOM_UI_PREVIEW
#import "ZomUIPreview-Swift.h"
#else
#import "pziOS-Swift.h"
#endif

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define ZOM_CS_DEBUGGED 0x10000000
static int pref_int(NSString *k, int def);
// iOS older than 19 uses the JVM's classic JIT path (no debugger-provided memory); preference zom.classicJIT forces it (1) or the other path (0).
static BOOL classic_jit(void) {
    int forced = pref_int(@"zom.classicJIT", -1);
    if (forced >= 0) return forced == 1;
    if (@available(iOS 19.0, *)) return NO;
    return YES;
}
// The debugger is attached (P_TRACED). On the classic path the script lets go again at once, and what stays is the CS_DEBUGGED code-signing flag that
// allows the JIT, so that counts too.
static BOOL debuggerAttached(void) {
    if (classic_jit()) { uint32_t cs = 0; if (csops(getpid(), 0 /* CS_OPS_STATUS */, &cs, sizeof cs) == 0 && (cs & ZOM_CS_DEBUGGED)) return YES; }
    struct kinfo_proc info; size_t size = sizeof info; info.kp_proc.p_flag = 0;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    sysctl(mib, 4, &info, &size, NULL, 0);
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

typedef int (*JLI_Launch_t)(int argc, char **argv, int jargc, const char **jargv,
                            int appclassc, const char **appclassv,
                            const char *fullversion, const char *dotversion,
                            const char *pname, const char *lname,
                            unsigned char javaargs, unsigned char cpwildcard,
                            unsigned char javaw, int ergo);


// ---- memory instrumentation: footprint, headroom and a breakdown by VM tag, logged every few seconds
static const char *kVMTagNames[512] = { [1] = "MALLOC", [2] = "MALLOC_SMALL", [3] = "MALLOC_LARGE", [4] = "MALLOC_HUGE", [6] = "REALLOC", [7] = "MALLOC_TINY", [8] = "MALLOC_LARGE_REUSABLE", [9] = "MALLOC_LARGE_REUSED", [10] = "ANALYSIS_TOOL", [11] = "MALLOC_NANO", [12] = "MALLOC_MEDIUM", [13] = "MALLOC_PROB_GUARD", [20] = "MACH_MSG", [21] = "IOKIT", [22] = "VM_RECLAIM", [30] = "STACK", [31] = "GUARD", [32] = "SHARED_PMAP", [33] = "DYLIB", [34] = "OBJC_DISPATCHERS", [35] = "UNSHARED_PMAP", [36] = "LIBCHANNEL", [40] = "APPKIT", [41] = "FOUNDATION", [42] = "COREGRAPHICS", [43] = "CORESERVICES", [44] = "JAVA", [45] = "COREDATA", [46] = "COREDATA_OBJECTIDS", [50] = "ATS", [51] = "LAYERKIT", [52] = "CGIMAGE", [53] = "TCMALLOC", [54] = "COREGRAPHICS_DATA", [55] = "COREGRAPHICS_SHARED", [56] = "COREGRAPHICS_FRAMEBUFFERS", [57] = "COREGRAPHICS_BACKINGSTORES", [58] = "COREGRAPHICS_XALLOC", [60] = "DYLD", [61] = "DYLD_MALLOC", [62] = "SQLITE", [63] = "JAVASCRIPT_CORE", [64] = "JAVASCRIPT_JIT_EXECUTABLE_ALLOCATOR", [65] = "JAVASCRIPT_JIT_REGISTER_FILE", [66] = "GLSL", [67] = "OPENCL", [68] = "COREIMAGE", [69] = "WEBCORE_PURGEABLE_BUFFERS", [70] = "IMAGEIO", [71] = "COREPROFILE", [72] = "ASSETSD", [73] = "OS_ALLOC_ONCE", [74] = "LIBDISPATCH", [75] = "ACCELERATE", [76] = "COREUI", [77] = "COREUIFILE", [78] = "GENEALOGY", [79] = "RAWCAMERA", [80] = "CORPSEINFO", [81] = "ASL", [82] = "SWIFT_RUNTIME", [83] = "SWIFT_METADATA", [84] = "DHMM", [85] = "DFR", [86] = "SCENEKIT", [87] = "SKYWALK", [88] = "IOSURFACE", [89] = "LIBNETWORK", [90] = "AUDIO", [91] = "VIDEOBITSTREAM", [92] = "CM_XPC", [93] = "CM_RPC", [94] = "CM_MEMORYPOOL", [95] = "CM_READCACHE", [96] = "CM_CRABS", [97] = "QUICKLOOK_THUMBNAILS", [98] = "ACCOUNTS", [99] = "SANITIZER", [100] = "IOACCELERATOR", [101] = "CM_REGWARP", [102] = "EAR_DECODER", [103] = "COREUI_CACHED_IMAGE_DATA", [104] = "COLORSYNC", [105] = "BTINFO", [106] = "CM_HLS", [107] = "COMPOSITOR_SERVICES", [108] = "DEBUG", [109] = "NEURAL", [230] = "ROSETTA", [231] = "ROSETTA_THREAD_CONTEXT", [232] = "ROSETTA_INDIRECT_BRANCH_MAP", [233] = "ROSETTA_RETURN_STACK", [234] = "ROSETTA_EXECUTABLE_HEAP", [235] = "ROSETTA_USER_LDT", [236] = "ROSETTA_ARENA", [239] = "ROSETTA_10", [240] = "APPLICATION_SPECIFIC_1", [241] = "APPLICATION_SPECIFIC_2", [242] = "APPLICATION_SPECIFIC_3", [243] = "APPLICATION_SPECIFIC_4", [244] = "APPLICATION_SPECIFIC_5", [245] = "APPLICATION_SPECIFIC_6", [246] = "APPLICATION_SPECIFIC_7", [247] = "APPLICATION_SPECIFIC_8", [248] = "APPLICATION_SPECIFIC_9", [249] = "APPLICATION_SPECIFIC_10", [250] = "APPLICATION_SPECIFIC_11", [251] = "APPLICATION_SPECIFIC_12", [252] = "APPLICATION_SPECIFIC_13", [253] = "APPLICATION_SPECIFIC_14", [254] = "APPLICATION_SPECIFIC_15", [255] = "APPLICATION_SPECIFIC_16", [256] = "COUNT" };
static void log_memory(void) {
    task_vm_info_data_t ti; mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&ti, &cnt) != KERN_SUCCESS) return;
    double bytesByTag[256] = {0}; vm_size_t pg = vm_page_size;
    vm_address_t addr = 0; vm_size_t size = 0; natural_t depth = 0;
    for (int guard = 0; guard < 200000; guard++) {
        vm_region_submap_info_data_64_t ri; mach_msg_type_number_t c = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &addr, &size, &depth, (vm_region_recurse_info_t)&ri, &c) != KERN_SUCCESS) break;
        if (ri.is_submap) { depth++; continue; }
        bytesByTag[ri.user_tag & 255] += ((double)ri.pages_dirtied + (double)ri.pages_swapped_out) * pg;
        addr += size;
    }
    char line[900]; int n = snprintf(line, sizeof line, "[mem] footprint %.0f MB (peak %.0f MB) avail %.0f MB |", ti.phys_footprint / 1048576.0, ti.ledger_phys_footprint_peak / 1048576.0, os_proc_available_memory() / 1048576.0);
    for (int k = 0; k < 8; k++) {
        int best = -1; double bv = 0;
        for (int t = 0; t < 256; t++) if (bytesByTag[t] > bv) { bv = bytesByTag[t]; best = t; }
        if (best < 0 || bv < 8 * 1048576.0) break;
        const char *nm = kVMTagNames[best]; char tmp[24]; if (!nm) { snprintf(tmp, sizeof tmp, "tag%d", best); nm = tmp; }
        n += snprintf(line + n, sizeof line - n, " %s=%.0f", nm, bv / 1048576.0);
        bytesByTag[best] = 0;
    }
    if (YES) {      // how much of the malloc regions is really in use (the rest is freed memory the allocator is holding on to)
        vm_address_t *zones = NULL; unsigned zc = 0; double inuse = 0, alloc = 0;
        if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &zc) == KERN_SUCCESS) for (unsigned z = 0; z < zc; z++) {
            malloc_statistics_t st = {0}; malloc_zone_statistics((malloc_zone_t *)zones[z], &st); inuse += st.size_in_use; alloc += st.size_allocated;
        }
        n += snprintf(line + n, sizeof line - n, " | malloc in-use=%.0f allocated=%.0f (%u zones)", inuse / 1048576.0, alloc / 1048576.0, zc);
        printf("%s MB\n", line);
        return;
    }
}
static void start_memory_logger(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *e = getenv("ZOMIOS_MEMLOG"); double iv = e ? atof(e) : 0; if (iv <= 0) return;      // opt-in: @env ZOMIOS_MEMLOG=5 in launch.args
        dispatch_queue_t q = dispatch_queue_create("pzios.memlog", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), (uint64_t)(iv * NSEC_PER_SEC), NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(t, ^{ log_memory(); });
        dispatch_resume(t);
        objc_setAssociatedObject(UIApplication.sharedApplication, "memlog", t, OBJC_ASSOCIATION_RETAIN);
    });
}


// ---- launcher settings (saved between launches) ----
static NSString *const kPrefShrink = @"zom.textureShrink";     // 0 off, 1 balanced, 2 strong
static NSString *const kPrefHiRes = @"zom.hiResTexturePacks";   // BOOL: texture2x
static NSString *const kPrefHeap = @"zom.heapLimit";           // 0 low (1.5 GB), 1 medium (2 GB), 2 high (2.5 GB)
static int pref_int(NSString *k, int def) { id v = [NSUserDefaults.standardUserDefaults objectForKey:k]; return v ? [v intValue] : def; }
// Java heap ceiling presets: {-Xmx, -Xms} in MB. High is what the tuned 8 GB-class devices run; lower ones leave more room for textures and the OS.
static const int kHeapMB[4][2] = { {1536, 512}, {2048, 768}, {2560, 1024}, {4096, 1536} };    // Very High is for devices with 12 GB of memory or more
static const int kYoungMB[4] = { 128, 160, 176, 192 };                                       // young generation size for pzGC: small, so each pause stays about one frame
static int default_heap_mode(void) {      // same rule as defaultHeapMode() in LauncherView.swift: from what iOS lets the app use, keeping ~1 GB spare
    long budget = (long)(os_proc_available_memory() / 1048576);
    if (budget <= 0) { unsigned long long gb = NSProcessInfo.processInfo.physicalMemory >> 30; return gb >= 11 ? 3 : gb >= 7 ? 2 : gb >= 5 ? 1 : 0; }
    return budget >= 7400 ? 3 : budget >= 5800 ? 2 : budget >= 5000 ? 1 : 0;
}
static const char *shrink_env_value(int mode) { return mode <= 0 ? "0" : mode == 1 ? "7" : "3"; }   // gl4es LIBGL_SHRINK: 7 = only >512px (not render targets), 3 = everything >256px

extern int zom_donor_prepare(uint64_t bytes, char *msg, size_t cap);      // Sources/RamDonorHost.m (private tree only)
extern bool zom_donor_map(char *base, size_t size);

// Rewrite keys in the game's options.ini (the game re-saves the whole file on exit, so we only touch our own keys).
static void apply_game_options(NSString *docs) {
    NSString *dir = [docs stringByAppendingPathComponent:@"home/Zomboid"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"options.ini"];
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *lines = [[txt componentsSeparatedByString:@"\n"] mutableCopy];
    if (lines.count && [lines.lastObject length] == 0) [lines removeLastObject];
    // doVideoEffects stays off: the game's preview videos need its Bink library (libbink64), which is a macOS-only library we do not ship; with the game's
    // default (on) a fresh install crashes at the main menu with "no bink64".
    NSDictionary<NSString *, NSString *> *want = @{ @"texture2x": (pref_int(kPrefHiRes, 0) && ZomGameFiles.has2xPacks) ? @"true" : @"false",
                                                    @"doVideoEffects": @"false" };
    for (NSString *key in want) {
        BOOL found = NO; NSString *prefix = [key stringByAppendingString:@"="];
        for (NSUInteger i = 0; i < lines.count; i++) if ([lines[i] hasPrefix:prefix]) { lines[i] = [prefix stringByAppendingString:want[key]]; found = YES; break; }
        if (!found) [lines addObject:[prefix stringByAppendingString:want[key]]];
    }
    [[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    printf("options.ini: texture2x=%s doVideoEffects=%s\n", want[@"texture2x"].UTF8String, want[@"doVideoEffects"].UTF8String);
}

// UI margins: ship the safe-area Lua script into the game's client Lua folder and tell it how far to keep the UI from the screen edges.
// The distances come from ZomMargins (LauncherView.swift): Auto from this device's corner radius and safe area, or the region saved by the
// screen margin editor (Custom).
static void install_ui_margin(NSString *docs, NSString *res) {
    static const char *kName[5] = {"off", "small", "auto", "large", "custom"};
    int level = MAX(0, MIN(4, pref_int(@"zom.uiMargin", 2)));
    int m[4] = {0, 0, 0, 0};
    if (level > 0) { NSArray<NSNumber *> *px = [ZomMargins gamePixelsWithLevel:level]; for (int i = 0; i < 4 && i < (int)px.count; i++) m[i] = px[i].intValue; }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [docs stringByAppendingPathComponent:@"game/media/lua/client"];
    NSString *src = [[NSBundle mainBundle] pathForResource:@"pziOSSafeArea" ofType:@"lua"];
    if (src && [fm fileExistsAtPath:dir]) {
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:@"ZomIOSSafeArea.lua"] error:nil];      // old name from earlier builds
        NSString *dst = [dir stringByAppendingPathComponent:@"pziOSSafeArea.lua"];
        NSData *a = [NSData dataWithContentsOfFile:src], *b = [NSData dataWithContentsOfFile:dst];
        if (![a isEqualToData:b]) { [fm removeItemAtPath:dst error:nil]; [fm copyItemAtPath:src toPath:dst error:nil]; }
    }
    NSString *luaDir = [docs stringByAppendingPathComponent:@"home/Zomboid/Lua"];
    [fm createDirectoryAtPath:luaDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *line = [NSString stringWithFormat:@"%d %d %d %d\n", m[0], m[1], m[2], m[3]];
    [line writeToFile:[luaDir stringByAppendingPathComponent:@"pzios_ui_margin.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    printf("settings: UI margins %s (left %d, top %d, right %d, bottom %d game px), script %s\n", kName[level], m[0], m[1], m[2], m[3], src ? "installed" : "missing");
}

// Default JVM arguments: written to Documents/launch.args when the file is missing, and replaced by a newer built-in default only while the
// file is still an unmodified default (its first line is "# zomios-default vN"). A file without that marker is the user's own and is kept.
static NSString *first_line(NSString *s) { NSRange r = [s rangeOfString:@"\n"]; return r.location == NSNotFound ? s : [s substringToIndex:r.location]; }
static void install_default_args(NSString *docs) {
    NSString *src = [[NSBundle mainBundle] pathForResource:@"default.launch" ofType:@"args"];
    NSString *def = src ? [NSString stringWithContentsOfFile:src encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!def) { printf("launch.args: built-in default missing from the app\n"); return; }
    NSString *dst = [docs stringByAppendingPathComponent:@"launch.args"];
    NSString *cur = [NSString stringWithContentsOfFile:dst encoding:NSUTF8StringEncoding error:nil];
    BOOL write = (cur == nil);
    if (cur) { NSString *tag = first_line(cur); if ([tag hasPrefix:@"# zomios-default"] && ![tag isEqualToString:first_line(def)]) write = YES; }
    if (write) { [def writeToFile:dst atomically:YES encoding:NSUTF8StringEncoding error:nil]; printf("launch.args: wrote the built-in default\n"); }
}

@interface VC : GCEventViewController
@property (strong) ZomLauncherModel *model;
@property (strong) NSString *logPath;
@property (strong) NSString *mainClass;
@property BOOL useArgsFile;
@end

@implementation VC
// A physical mouse (reported by the GLFW layer) captures the system pointer so the game can draw its own cursor from relative motion.
static BOOL g_wantPointerLock;
- (BOOL)prefersPointerLocked { return g_wantPointerLock; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }      // no swipe-home bar over the launcher or the game
- (void)mouseStateChanged:(NSNotification *)n { g_wantPointerLock = [n.object boolValue]; [self setNeedsUpdateOfPrefersPointerLocked]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(mouseStateChanged:) name:@"ZomIOSMouseConnected" object:nil];
    self.controllerUserInteractionEnabled = NO;   // deliver controller buttons (incl. Menu/Start) to the game, not to system UI navigation
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];

    // The launcher screen itself is SwiftUI (LauncherView.swift); it writes the same UserDefaults keys read in launchJVM.
    self.model = [ZomLauncherModel new];
#ifndef ZOM_UI_PREVIEW
    [ZomJITHost attachToModel:self.model];
#endif
    __weak VC *ws = self;
    UIViewController *ui = [ZomLauncherUI makeControllerWithModel:self.model onRun:^(NSInteger mode) { [ws runMode:mode]; }];
    [self addChildViewController:ui];
    ui.view.frame = self.view.bounds; ui.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:ui.view];
    [ui didMoveToParentViewController:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSArray *args = NSProcessInfo.processInfo.arguments;
    if ([args containsObject:@"-autorun-xint"]) [self runMode:0];
    else if ([args containsObject:@"-autorun-jit"]) [self runMode:1];
    else if ([args containsObject:@"-autorun-natives"]) [self runMode:2];
    else if ([args containsObject:@"-autorun-args"]) [self runMode:3];
}

- (void)append:(NSString *)s {
    // coalesce: keep only the tail and refresh the text view at most twice a second (the log can be huge)
    static NSMutableString *pending; static BOOL scheduled; static NSLock *lock;
    static dispatch_once_t once; dispatch_once(&once, ^{ pending = [NSMutableString string]; lock = [NSLock new]; });
    [lock lock];
    [pending appendString:s];
    if (pending.length > 20000) [pending deleteCharactersInRange:NSMakeRange(0, pending.length - 20000)];
    BOOL need = !scheduled; scheduled = YES;
    [lock unlock];
    if (!need) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [lock lock]; NSString *t = [pending copy]; scheduled = NO; [lock unlock];
        [self.model setLog:t];
    });
}

- (void)runMode:(NSInteger)mode {
#ifdef ZOM_UI_PREVIEW
    [self append:@"UI preview build: the JVM is not available here.\n"]; return;
#endif
    if (self.model.isRunning) return;
    BOOL jit = mode != 0; self.mainClass = mode == 2 ? @"NativeTest" : @"Hello"; self.useArgsFile = mode == 3;
    [self.model setRunning:YES];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    // iOS reports /var/mobile/... but the real path is /private/var/mobile/...; the game mixes both (cwd vs user.home) and its mod script
    // loader then fails to make mod paths relative, so hand the JVM only the canonical form.
    { char rp[PATH_MAX]; if (realpath(docs.fileSystemRepresentation, rp)) docs = [NSString stringWithUTF8String:rp]; }
    self.logPath = [docs stringByAppendingPathComponent:@"jvm.log"];
    {   // keep the previous run's log next to the new one, so a crash can still be reported after the next launch
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *last = [docs stringByAppendingPathComponent:@"jvm-last.log"];
        [fm removeItemAtPath:last error:nil];
        if ([fm fileExistsAtPath:self.logPath]) [fm moveItemAtPath:self.logPath toPath:last error:nil];
    }

    // Pipe stdout/stderr (JVM output included) to both the log file and the on-screen view.
    int fds[2]; pipe(fds);
    dup2(fds[1], STDOUT_FILENO); dup2(fds[1], STDERR_FILENO);
    setvbuf(stdout, NULL, _IONBF, 0);
    FILE *lf = fopen(self.logPath.fileSystemRepresentation, "w");
    int rfd = fds[0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char buf[2048]; ssize_t n;
        while ((n = read(rfd, buf, sizeof buf - 1)) > 0) {
            buf[n] = 0;
            { static BOOL booted; if (!booted && strstr(buf, "version=") != NULL) { booted = YES; [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"zom.gcOK"]; [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"zom.ramDonorOK"]; } }   // the JVM got far enough that its collector works
            if (lf) { fwrite(buf, 1, n, lf); fflush(lf); }
            [self append:[NSString stringWithUTF8String:buf] ?: @"<non-utf8>\n"];
        }
    });

    NSThread *t = [[NSThread alloc] initWithBlock:^{ [self launchJVM:jit docs:docs]; }];
    t.stackSize = 16 << 20; t.name = @"jvm-launcher";
    [t start];
}

// A failure before the JVM exists: say why in the log and give the launcher its buttons back. Without this, PLAY stays greyed
// out for the rest of the launch, because the engine can only be started once per process.
- (void)failEarly:(NSString *)why {
    printf("%s\n", why.UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{ [self.model setRunning:NO]; });
}

- (void)launchJVM:(BOOL)jit docs:(NSString *)docs {
    if (self.useArgsFile && !ZomGameFiles.installed) {
        [self failEarly:@"Game files are not installed. Open the setup guide (Game Files button) to import them."];
        return;
    }
    [ZomGameFiles excludeFromBackup];
    NSString *res = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"runtime"];
    NSString *jre = [res stringByAppendingPathComponent:@"jre"];
    NSString *classes = [res stringByAppendingPathComponent:@"test"];
    NSString *libjli = [jre stringByAppendingPathComponent:@"lib/libjli.dylib"];
    // Persistent texture cache lives in Library/Caches (not backed up, may be purged by iOS under storage pressure -- it just re-encodes).
    // Computed before HOME is redirected to Documents below.
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"zomios-astc"];
    [[NSFileManager defaultManager] createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("ZOMIOS_CACHE_DIR", caches.UTF8String, 1);
        setenv("JAVA_HOME", jre.UTF8String, 1);
    setenv("HOME", docs.UTF8String, 1);
    setenv("TMPDIR", NSTemporaryDirectory().UTF8String, 1);
    printf("device: %s\n", ZomDevice.summary.UTF8String);
#ifndef ZOM_UI_PREVIEW
    printf("%s\n", ZomJITHost.diagnosticSummary.UTF8String);
#endif
    printf("jre: %s\nmode: %s\n", jre.UTF8String, jit ? "JIT (TXM mirror-mapped)" : "interpreter");
    printf("memory: physical %.1f GB, available to app %.0f MB\n", NSProcessInfo.processInfo.physicalMemory / 1073741824.0, os_proc_available_memory() / 1048576.0);
#ifndef ZOM_UI_PREVIEW
    BOOL builtinJIT = [ZomJITHost startIfSelected];
#else
    BOOL builtinJIT = NO;
#endif
    printf(builtinJIT ? "waiting for debugger (built-in StikJIT is attaching)...\n" : "waiting for debugger (run the script in StikDebug now)...\n");
    while (!debuggerAttached()) {
#ifndef ZOM_UI_PREVIEW
        NSString *jitFail = ZomJITHost.failureMessage;
        if (jitFail) { printf("JIT failed: %s\n", jitFail.UTF8String); dispatch_async(dispatch_get_main_queue(), ^{ [self.model setRunning:NO]; }); return; }
#endif
        usleep(100000);
    }
    printf("debugger attached, starting JVM\n");

    // RemoteIO output (used by FMOD through libfmodhal) needs an active playback audio session.
    NSError *aerr = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&aerr];
    [[AVAudioSession sharedInstance] setActive:YES error:&aerr];
    printf("audio session: %s (%.0f Hz)\n", aerr ? aerr.localizedDescription.UTF8String : "active", [AVAudioSession sharedInstance].sampleRate);
    setenv("ZOMIOS_FMODHAL_LOG", "1", 0);

    void *h = dlopen(libjli.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { [self failEarly:[NSString stringWithFormat:@"dlopen libjli failed: %s", dlerror()]]; return; }
    if (pref_int(@"zom.framePool", 0)) { setenv("ZOMIOS_FRAMEPOOL", "1", 1); printf("settings: per-frame autorelease pool on\n"); }
    JLI_Launch_t launch = (JLI_Launch_t)dlsym(h, "JLI_Launch");
    if (!launch) { [self failEarly:@"JLI_Launch not found"]; return; }

    NSMutableArray<NSString *> *a = [NSMutableArray arrayWithObject:[jre stringByAppendingPathComponent:@"bin/java"]];
    [a addObjectsFromArray:@[@"-XX:+UnlockExperimentalVMOptions", @"-XX:+DisablePrimordialThreadGuardPages",
                             @"-Xshare:off", @"-Xmx512m", @"-Djava.awt.headless=true",
                             @"-XX:+MirrorMappedCodeCache", @"-XX:ReservedCodeCacheSize=32M"]];
    // Even -Xint emits machine code (template interpreter), so both modes need the debugger-provided RX region.
    if (!jit) [a addObject:@"-Xint"];
    [a addObjectsFromArray:@[@"-cp", [NSString stringWithFormat:@"%@:%@/projectzomboid.jar", classes, docs], self.mainClass]];
    if ([self.mainClass isEqualToString:@"NativeTest"]) [a addObject:[res stringByAppendingPathComponent:@"natives"]];

    if (self.useArgsFile) {
        // Documents/launch.args: one JVM/launcher argument per line; $DOCS, $BUNDLE and $JRE are substituted.
        install_default_args(docs);
        NSString *txt = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"launch.args"] encoding:NSUTF8StringEncoding error:nil];
        if (!txt) { [self failEarly:@"Documents/launch.args not found"]; return; }
        a = [NSMutableArray arrayWithObject:[jre stringByAppendingPathComponent:@"bin/java"]];
        for (NSString *line in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!t.length || [t hasPrefix:@"#"]) continue;
            t = [t stringByReplacingOccurrencesOfString:@"$DOCS" withString:docs];
            t = [t stringByReplacingOccurrencesOfString:@"$BUNDLE" withString:res];
            t = [t stringByReplacingOccurrencesOfString:@"$JRE" withString:jre];
            if ([t hasPrefix:@"@env "]) { NSString *kv = [t substringFromIndex:5]; NSRange eq = [kv rangeOfString:@"="]; if (eq.location != NSNotFound) { setenv([kv substringToIndex:eq.location].UTF8String, [kv substringFromIndex:eq.location + 1].UTF8String, 1); printf("env %s\n", kv.UTF8String); } continue; }
            if ([t hasPrefix:@"@chdir "]) { NSString *d = [t substringFromIndex:7]; printf("chdir %s -> %d\n", d.UTF8String, chdir(d.UTF8String)); continue; }
            [a addObject:t];
        }
        // launcher memory preset replaces any heap sizing in the args file
        int heapMode = MAX(0, MIN(3, pref_int(kPrefHeap, default_heap_mode())));
        for (NSInteger i = (NSInteger)a.count - 1; i >= 1; i--) if ([a[i] hasPrefix:@"-Xmx"] || [a[i] hasPrefix:@"-Xms"]) [a removeObjectAtIndex:i];
        [a insertObject:[NSString stringWithFormat:@"-Xms%dm", kHeapMB[heapMode][1]] atIndex:1];
        [a insertObject:[NSString stringWithFormat:@"-Xmx%dm", kHeapMB[heapMode][0]] atIndex:1];
        printf("settings: memory limit -Xmx%dm -Xms%dm\n", kHeapMB[heapMode][0], kHeapMB[heapMode][1]);
        // C2 (optimizing) compiler: the args file runs C1 only (-XX:TieredStopAtLevel=1); the setting lifts that limit
        // JIT compiler tiers: 0 C1 only (the args file's -XX:TieredStopAtLevel=1), 1 C1 + C2 gentle, 2 C1 + C2 full. Gentle raises the C2 thresholds
        // about 4x, so only code that runs very often gets the optimizing compiler: less CPU, and the code cache fills more slowly.
        NSUserDefaults *jud = NSUserDefaults.standardUserDefaults;
        int jitTier = [jud objectForKey:@"zom.jitCompiler"] ? (int)[jud integerForKey:@"zom.jitCompiler"] : ([jud boolForKey:@"zom.c2"] ? 2 : 0);     // zom.c2 was the old on/off switch
        jitTier = MAX(0, MIN(2, jitTier));
        if (jitTier > 0) {
            for (NSInteger i = (NSInteger)a.count - 1; i >= 1; i--) if ([a[i] hasPrefix:@"-XX:TieredStopAtLevel"]) [a removeObjectAtIndex:i];
            if (jitTier == 1) {
                [a insertObject:@"-XX:Tier4BackEdgeThreshold=160000" atIndex:1];
                [a insertObject:@"-XX:Tier4CompileThreshold=60000" atIndex:1];
                [a insertObject:@"-XX:Tier4MinInvocationThreshold=2400" atIndex:1];
                [a insertObject:@"-XX:Tier4InvocationThreshold=20000" atIndex:1];
            }
        }
        // Code cache cleanup: the JVM requests an unloading collection (a full, stop-the-world one with Parallel) whenever 15% of the cache has been
        // allocated since the last one, about 19 MB of 128 MB, which showed up as 0.1 to 0.9 s stalls. 60% makes it rare; the "free space is low"
        // trigger (10% left) still protects against a full cache.
        if (![[a componentsJoinedByString:@" "] containsString:@"SweeperThreshold"]) [a insertObject:(jitTier > 0 ? @"-XX:SweeperThreshold=100" : @"-XX:SweeperThreshold=60") atIndex:1];
        // C2 keeps large profiled tier-3 code, which used up 60% of 128 MB after about 110 s and forced a 0.9 s full GC. With C2 on, double the cache and
        // set the threshold to 100%, so only the "10% free" trigger can force an unloading GC (a threshold of 100 can never be exceeded).
        if (jitTier > 0) for (NSUInteger i = 1; i < a.count; i++) if ([a[i] hasPrefix:@"-XX:ReservedCodeCacheSize"]) a[i] = @"-XX:ReservedCodeCacheSize=256M";
        { static const char *kJitName[3] = {"C1 only", "C1 + C2 (gentle thresholds)", "C1 + C2 (full)"}; printf("settings: JIT compiler %s\n", kJitName[jitTier]); }
        // ZombieBuddy (Developer Tools): adds -javaagent:ZombieBuddy.jar. The jar goes in the game folder (Files > pziOS > game) or next to it in the pziOS folder; without it
        // the JVM would refuse to start, so the argument is only added when the file is there.
        if (pref_int(@"zom.zombieBuddy", 0)) {
            NSString *zb = nil;
            for (NSString *dir in @[[docs stringByAppendingPathComponent:@"game"], docs]) { NSString *c = [dir stringByAppendingPathComponent:@"ZombieBuddy.jar"]; if ([NSFileManager.defaultManager fileExistsAtPath:c]) { zb = c; break; } }
            if (zb) { [a insertObject:[@"-javaagent:" stringByAppendingString:zb] atIndex:1]; printf("settings: ZombieBuddy on (-javaagent:%s)\n", zb.UTF8String); }
            else printf("settings: ZombieBuddy is on but ZombieBuddy.jar was not found in Documents/game or Documents, so it is skipped\n");
        }
        // Graphics backend Zink (experimental, Developer Tools). Mesa Zink + MoltenVK replace gl4es + MetalANGLE; LWJGL then loads GL from libGLzink (trampolines into Mesa).
        if (pref_int(@"zom.zinkBackend", 0)) {
            setenv("ZOMIOS_ZINK", "1", 1);
            if (pref_int(@"zom.zinkLog", 0)) { setenv("ZOMIOS_ZINKLOG", "1", 1); printf("settings: Zink detailed log on\n"); }
            for (NSUInteger i = 1; i < a.count; i++) if ([a[i] hasPrefix:@"-Dorg.lwjgl.opengl.libname="]) a[i] = [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%@/runtime/natives/zink/libGLzink.dylib", NSBundle.mainBundle.resourcePath];
            printf("settings: graphics backend Zink over MoltenVK (experimental)\n");
        }
        // JIT path: iOS 19 and later (26/27) get their executable memory from the debugger as a mirror-mapped region. Older systems (iOS 17 and 18) have no
        // such mapping to hand out, so the JVM runs its classic path there: an ordinary code cache whose pages are switched between writable and executable
        // as needed while the debugger is attached. Preference zom.classicJIT forces it for testing: 1 classic, 0 mirror-mapped, unset = by iOS version.
        {
            if (classic_jit()) {
                for (NSInteger i = (NSInteger)a.count - 1; i >= 1; i--) if ([a[i] isEqualToString:@"-XX:+MirrorMappedCodeCache"]) [a removeObjectAtIndex:i];
                printf("settings: JIT path classic (no mirror-mapped code cache) on iOS %s\n", UIDevice.currentDevice.systemVersion.UTF8String);
            }
        }
        // Garbage collector: 0 Parallel (the args file), 3 Tuned Parallel, 2 SGC (generational Shenandoah), 4 SGC Async (1 was ZGC, which cannot start on iOS). Any non-default choice is a trial until the game has booted; if the previous trial never got that
        // far, it does not work here, so go back to Parallel.
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        int gc = (int)[ud integerForKey:@"zom.gc"];
        static const char *kGCName[5] = {"Parallel", "ZGC", "SGC (generational Shenandoah)", "pzGC (tuned Parallel)", "pzSGC"};
        if (gc != 0 && [ud boolForKey:@"zom.gcTrial"] && ![ud boolForKey:@"zom.gcOK"]) {
            printf("settings: the last %s launch never booted, so it is switched off\n", kGCName[MIN(MAX(gc, 0), 4)]);
            [ud setInteger:0 forKey:@"zom.gc"]; [ud setBool:NO forKey:@"zom.gcTrial"]; [ud setBool:YES forKey:@"zom.gcReverted"];
            gc = 0;
        }
        if (gc != 0) {
            [ud setBool:YES forKey:@"zom.gcTrial"]; [ud setBool:NO forKey:@"zom.gcOK"]; [ud synchronize];
            if (gc == 2 || gc == 4) for (NSInteger i = (NSInteger)a.count - 1; i >= 1; i--) if ([a[i] hasPrefix:@"-XX:+UseParallelGC"] || [a[i] hasPrefix:@"-XX:ParallelGCThreads"]) [a removeObjectAtIndex:i];
            if (gc == 2) {
                if (![a containsObject:@"-XX:+UnlockExperimentalVMOptions"]) [a insertObject:@"-XX:+UnlockExperimentalVMOptions" atIndex:1];
                [a insertObject:@"-XX:ShenandoahGCMode=generational" atIndex:1];
                [a insertObject:@"-XX:+UseShenandoahGC" atIndex:1];
            } else if (gc == 4) {
                // pzSGC: the same collector, set to keep ahead of the game. The first run with plain SGC fell behind while the world loaded (the heap
                // reached 95% full) and fell back to two stop-the-world collections of 220 and 280 ms. Here a cycle starts when 35% of the heap is free
                // instead of 10%, the reserve for allocation spikes is 4x bigger, three concurrent threads do the work, and the memory is kept instead of
                // being handed back and re-requested. It uses more memory than SGC for that headroom.
                for (NSString *f in @[@"-XX:-ShenandoahUncommit", @"-XX:ConcGCThreads=3", @"-XX:ShenandoahAllocSpikeFactor=20", @"-XX:ShenandoahMinFreeThreshold=35",
                                      @"-XX:ShenandoahGCMode=generational", @"-XX:+UseShenandoahGC"]) [a insertObject:f atIndex:1];
                [a insertObject:@"-XX:+UnlockExperimentalVMOptions" atIndex:1];     // must come before the experimental Shenandoah flags above
            } else if (gc == 3) {
                // pzGC: Parallel, shaped by what the log of the game showed. A collection's pause grows with the volume allocated since the last one (most of
                // what the game allocates survives), so a bigger young generation only makes the pauses rarer and longer; a small one keeps each pause near
                // a single frame. Survivors are promoted after two collections instead of being copied again and again (as both generational low-pause
                // collectors do), reference processing runs in parallel, and the metadata size is set up front so the "Metadata GC Threshold" full
                // collections during loading don't happen.
                for (NSInteger i = (NSInteger)a.count - 1; i >= 1; i--) if ([a[i] hasPrefix:@"-Xmn"] || [a[i] hasPrefix:@"-XX:NewSize"] || [a[i] hasPrefix:@"-XX:MaxTenuringThreshold"] || [a[i] hasPrefix:@"-XX:MetaspaceSize"]) [a removeObjectAtIndex:i];
                [a insertObject:@"-XX:+ParallelRefProcEnabled" atIndex:1];
                [a insertObject:@"-XX:MaxTenuringThreshold=2" atIndex:1];
                [a insertObject:@"-XX:MetaspaceSize=256m" atIndex:1];
                [a insertObject:[NSString stringWithFormat:@"-Xmn%dm", kYoungMB[heapMode]] atIndex:1];
            }
        }
        // RAM donor heap (experimental): the Java heap lives in memory held by the donor extension (another process), so iOS does not charge it to the
        // app. The donor memory is prepared here; the JVM maps it over its heap range through PZ_DONOR_MAP_FN (JRE patch). Same trial rule as the others.
        {
            NSUserDefaults *hud = NSUserDefaults.standardUserDefaults;
            if ([hud boolForKey:@"zom.ramDonorHeap"]) {
                if ([hud boolForKey:@"zom.ramDonorTrial"] && ![hud boolForKey:@"zom.ramDonorOK"]) {
                    printf("settings: the last launch with the RAM donor heap never booted, so it is switched off\n");
                    [hud setBool:NO forKey:@"zom.ramDonorHeap"]; [hud setBool:NO forKey:@"zom.ramDonorTrial"];
                } else {
                    [hud setBool:YES forKey:@"zom.ramDonorTrial"]; [hud setBool:NO forKey:@"zom.ramDonorOK"]; [hud synchronize];
                    // Heap size: the Memory Limit tier, or a bigger one chosen for the donor (0 = tier, 1..4 = 3..6 GB, default 1 = 3 GB). The heap is not limited by the app's own
                    // budget here, only by the donors and by the device's physical memory.
                    int donorGB = pref_int(@"zom.donorHeapGB", 1) > 0 ? 2 + pref_int(@"zom.donorHeapGB", 1) : 0;
                    int heapMB = donorGB > 0 ? donorGB * 1024 : kHeapMB[heapMode][0];
                    long physMB = (long)(NSProcessInfo.processInfo.physicalMemory / 1048576);
                    if (heapMB > physMB - 2048) { heapMB = (int)((physMB - 2048) / 256 * 256); printf("settings: RAM donor heap limited to %d MB (device memory %ld MB)\n", heapMB, physMB); }
                    char msg[4096] = {0};
                    if (zom_donor_prepare(((uint64_t)heapMB + 128) << 20, msg, sizeof msg)) {
                        char env[32]; snprintf(env, sizeof env, "%llx", (unsigned long long)(uintptr_t)&zom_donor_map);
                        setenv("PZ_DONOR_MAP_FN", env, 1);
                        if (heapMB != kHeapMB[heapMode][0]) {
                            for (NSInteger i = (NSInteger)a.count - 1; i >= 1; i--) if ([a[i] hasPrefix:@"-Xmx"] || [a[i] hasPrefix:@"-Xms"]) [a removeObjectAtIndex:i];
                            [a insertObject:[NSString stringWithFormat:@"-Xms%dm", MIN(heapMB / 2, 2048)] atIndex:1];
                            [a insertObject:[NSString stringWithFormat:@"-Xmx%dm", heapMB] atIndex:1];
                        }
                        printf("%ssettings: RAM donor heap (experimental): the Java heap (-Xmx%dm) will live in donated memory (trial until the game boots)\n", msg, heapMB);
                    } else printf("%ssettings: RAM donor heap could not be prepared, using ordinary memory (-Xmx%dm)\n", msg, kHeapMB[heapMode][0]);
                }
            }
        }
        printf("settings: garbage collector %s%s\n", kGCName[MIN(MAX(gc, 0), 4)], gc != 0 ? " (trial until the game boots)" : "");
        printf("launch.args: %lu args\n", (unsigned long)a.count - 1);
        // launcher settings override anything the args file set for these
        int shrink = pref_int(kPrefShrink, 1);
        setenv("LIBGL_SHRINK", shrink_env_value(shrink), 1);
        setenv("LIBGL_NOERROR", "1", 0);      // gl4es skips its per-call glGetError checks (they can stall the GPU layer); args file can override
        { id astcPref = [NSUserDefaults.standardUserDefaults objectForKey:@"zom.astc"]; BOOL astcOn = astcPref ? [astcPref boolValue] : YES;
          setenv("ZOMIOS_ASTC", astcOn ? "512" : "0", 1); printf("settings: ASTC compression %s\n", astcOn ? "on" : "off"); }
        printf("settings: texture shrink=%s (LIBGL_SHRINK=%s), 2x packs=%s\n", shrink == 0 ? "off" : shrink == 1 ? "balanced" : "strong", shrink_env_value(shrink), pref_int(kPrefHiRes, 0) ? "on" : "off");
        {   // render resolution: the game's logical height; read by the GLFW layer when the window is made, and by the UI margin maths
            static const int kRenderH[4] = {540, 720, 900, 1080};
            int ri = MAX(0, MIN(3, pref_int(@"zom.renderRes", UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 2 : 1)));
            char hb[8]; snprintf(hb, sizeof hb, "%d", kRenderH[ri]); setenv("ZOMIOS_HEIGHT", hb, 1);
            printf("settings: render resolution %dp\n", kRenderH[ri]);
            static const char *kAspect[5] = {NULL, "1.3333", "1.5", "1.6", "1.7778"};
            int ai = MAX(0, MIN(4, pref_int(@"zom.simAspect", 0)));
            if (ai > 0) { setenv("ZOMIOS_ASPECT", kAspect[ai], 1); printf("settings: simulated aspect ratio %s\n", kAspect[ai]); } else unsetenv("ZOMIOS_ASPECT");
        }
        // Controller remapping and deadzone (Settings > Controls > Controller): handed to the GLFW layer as JSON. Without a
        // saved configuration the layer keeps its standard mapping and no deadzone.
        {
            NSString *padCfg = [NSUserDefaults.standardUserDefaults stringForKey:@"zom.controllerConfig"];
            if (padCfg.length) { setenv("ZOMIOS_PAD_CONFIG", padCfg.UTF8String, 1); printf("settings: controller remap applied\n"); }
            else unsetenv("ZOMIOS_PAD_CONFIG");
        }
        install_ui_margin(docs, res);
        apply_game_options(docs);
    }
    if (pref_int(@"zom.memLog", 0)) { setenv("ZOMIOS_GPULOG", "1", 1); setenv("ZOMIOS_MEMLOG", "5", 1); printf("settings: memory log every 5 s\n"); }       // developer switch, overrides the args file
    start_memory_logger();     // after launch.args so its @env ZOMIOS_MEMLOG is honoured
    for (NSString *x in a) if ([x hasPrefix:@"-XX:"] || [x hasPrefix:@"-Xm"] || [x hasPrefix:@"-Xs"]) printf("jvm-arg: %s\n", x.UTF8String);
    int argc = (int)a.count; char **argv = calloc(argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) argv[i] = strdup(a[i].UTF8String);
    int rc = launch(argc, argv, 0, NULL, 0, NULL, "25.0.1-internal", "25.0", "java", "openjdk", 0, 1, 0, 0);
    printf("\nJLI_Launch returned %d\n", rc);
    // The JVM did not start (or has exited). If this launch was a ZGC trial that never booted, ZGC does not work here: switch back to Parallel
    // now, let the launcher say so, and let it be used again.
    {
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        if ([ud integerForKey:@"zom.gc"] != 0 && [ud boolForKey:@"zom.gcTrial"] && ![ud boolForKey:@"zom.gcOK"]) {
            printf("settings: the chosen garbage collector did not start, switching back to Parallel\n");
            [ud setInteger:0 forKey:@"zom.gc"]; [ud setBool:NO forKey:@"zom.gcTrial"]; [ud setBool:YES forKey:@"zom.gcReverted"];
        }
        if ([ud boolForKey:@"zom.ramDonorHeap"] && [ud boolForKey:@"zom.ramDonorTrial"] && ![ud boolForKey:@"zom.ramDonorOK"]) { [ud setBool:NO forKey:@"zom.ramDonorHeap"]; [ud setBool:NO forKey:@"zom.ramDonorTrial"]; }
        dispatch_async(dispatch_get_main_queue(), ^{ [self.model setRunning:NO]; });
    }
}
@end

@interface AD : UIResponder <UIApplicationDelegate>
@end
@implementation AD
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = NSClassFromString(@"SceneDelegate");
    return c;
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [VC new];
    [self.window makeKeyAndVisible];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // First run only: pick the Memory Limit from the memory iOS grants this device and keep it. Measured now, before the app has grown, and
        // stored so the choice doesn't shift between launches; the user can change it in Settings.
        if (![NSUserDefaults.standardUserDefaults boolForKey:@"zom.devSwitchesReset1"]) { [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"zom.memLog"]; [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"zom.simAspect"]; [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"zom.devSwitchesReset1"]; }
        if (![NSUserDefaults.standardUserDefaults boolForKey:@"zom.devSwitchesReset2"]) { for (NSString *k in @[@"zom.framePool"]) [NSUserDefaults.standardUserDefaults setBool:NO forKey:k]; [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"zom.devSwitchesReset2"]; }      // experimental switches start off      // the memory-test switches start off
        if (![NSUserDefaults.standardUserDefaults objectForKey:kPrefHeap]) [NSUserDefaults.standardUserDefaults setInteger:default_heap_mode() forKey:kPrefHeap];
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AD class]));
    }
}
