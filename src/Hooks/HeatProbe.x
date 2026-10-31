//
//  HeatProbe.x
//  NeoFreeBird (fork port)
//
//  Heat diagnostics for the v7 test builds. Every 30 s, and on every thermal
//  state change, one "heat" line goes into the session log that
//  "📤 Save diagnostics as a file" exports:
//   - process CPU over the window, the busiest threads by name, the main
//     thread's busy share and run loop wakeups per second (an idle app sleeps;
//     a layout or animation loop keeps waking it),
//   - per-second rates of the hot hook paths (NFBHeat.h counters),
//   - finished network requests per endpoint, playing AVPlayers and running
//     display links (by target class), thermal state, low power mode.
//  When one thread burns more than a third of a core, a few stack samples of
//  it follow as image+offset frames, symbolised offline against the IPA.
//

#import "HookHelpers.h"
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <pthread.h>

void NFBLogEvent(NSString* msg);  // Streaming.x

_Atomic uint64_t NFBHeatCounters[NFBHeatCounterCount];

static const char* const NFBHeatCounterNames[NFBHeatCounterCount] = {
    "fs", "fsMiss", "set", "setMiss", "viewBg", "viewWin", "colorResolve", "paletteColor",
    "dynColor", "palette", "font", "colsLayout", "tick", "refresh", "net",
};

static const NSTimeInterval NFBHeatWindow = 30.0;

static mach_port_t NFBHeatMainThread = MACH_PORT_NULL;
static mach_port_t NFBHeatSamplerThread = MACH_PORT_NULL;
static _Atomic uint64_t NFBHeatMainWakeups;
static _Atomic uint64_t NFBHeatMainBusyNs;
static _Atomic uint64_t NFBHeatMainAwakeSince;
static _Atomic bool NFBHeatInBackground;
static _Atomic bool NFBHeatWakeEarly;

static uint64_t NFBHeatNowNs(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// MARK: - Main run loop: wakeups and busy time

static void NFBHeatInstallRunLoopObservers(void) {
    // First observer after the sleep ends, last one before it starts again, so
    // the busy share includes Core Animation's commit at the end of the pass.
    CFRunLoopObserverRef woke = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, kCFRunLoopAfterWaiting, true, LONG_MIN,
        ^(__unused CFRunLoopObserverRef observer, __unused CFRunLoopActivity activity) {
            atomic_store_explicit(&NFBHeatMainAwakeSince, NFBHeatNowNs(), memory_order_relaxed);
            atomic_fetch_add_explicit(&NFBHeatMainWakeups, 1, memory_order_relaxed);
        });
    CFRunLoopObserverRef sleeping = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, LONG_MAX,
        ^(__unused CFRunLoopObserverRef observer, __unused CFRunLoopActivity activity) {
            uint64_t since = atomic_exchange_explicit(&NFBHeatMainAwakeSince, 0, memory_order_relaxed);
            if (since) {
                atomic_fetch_add_explicit(&NFBHeatMainBusyNs, NFBHeatNowNs() - since,
                                          memory_order_relaxed);
            }
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), woke, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetMain(), sleeping, kCFRunLoopCommonModes);
    CFRelease(woke);
    CFRelease(sleeping);
}

// MARK: - Network responses by endpoint

static os_unfair_lock NFBHeatNetworkLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString*, NSNumber*>* NFBHeatNetworkCounts;

static NSString* NFBHeatEndpoint(NSURL* url) {
    NSArray<NSString*>* parts = url.path.pathComponents;
    NSUInteger graphql = [parts indexOfObject:@"graphql"];
    // /i/api/graphql/<queryId>/<OperationName>: the operation names the request.
    NSString* name = graphql != NSNotFound && graphql + 2 < parts.count ? parts[graphql + 2]
                                                                        : parts.lastObject;
    return [NSString stringWithFormat:@"%@/%@", url.host ?: @"?", name ?: @"-"];
}

%hook TNLResponseInfo
- (instancetype)initWithFinalURLRequest:(NSURLRequest*)request
                            URLResponse:(NSURLResponse*)response
                                 source:(NSInteger)source
                                   data:(NSData*)data
                      temporarySavedFile:(id)temporarySavedFile {
    NFBHeatCount(NFBHeatNetworkResponse);
    NSURL* url = request.URL;
    if (url) {
        NSString* endpoint = NFBHeatEndpoint(url);
        os_unfair_lock_lock(&NFBHeatNetworkLock);
        if (!NFBHeatNetworkCounts) NFBHeatNetworkCounts = [NSMutableDictionary new];
        NFBHeatNetworkCounts[endpoint] = @(NFBHeatNetworkCounts[endpoint].unsignedIntegerValue + 1);
        os_unfair_lock_unlock(&NFBHeatNetworkLock);
    }
    return %orig;
}
%end

static NSString* NFBHeatTakeNetworkSummary(void) {
    os_unfair_lock_lock(&NFBHeatNetworkLock);
    NSDictionary<NSString*, NSNumber*>* counts = [NFBHeatNetworkCounts copy];
    [NFBHeatNetworkCounts removeAllObjects];
    os_unfair_lock_unlock(&NFBHeatNetworkLock);
    NSArray<NSString*>* keys = [counts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
        return [b compare:a];
    }];
    NSMutableArray<NSString*>* top = [NSMutableArray array];
    for (NSString* key in keys) {
        if (top.count == 6) break;
        [top addObject:[NSString stringWithFormat:@"%@x%@", key, counts[key]]];
    }
    return top.count ? [top componentsJoinedByString:@" "] : @"-";
}

// MARK: - Playing videos and running display links

static NSHashTable<AVPlayer*>* NFBHeatPlayers;
static NSHashTable<CADisplayLink*>* NFBHeatDisplayLinks;
static char NFBHeatDisplayLinkTargetKey;

static void NFBHeatTrackPlayer(AVPlayer* player) {
    __weak AVPlayer* weakPlayer = player;
    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayer* strongPlayer = weakPlayer;
        if (!strongPlayer) return;
        if (!NFBHeatPlayers) NFBHeatPlayers = [NSHashTable weakObjectsHashTable];
        [NFBHeatPlayers addObject:strongPlayer];
    });
}

%hook AVPlayer
- (void)setRate:(float)rate {
    %orig;
    if (rate > 0.0f) NFBHeatTrackPlayer(self);
}

- (void)play {
    %orig;
    NFBHeatTrackPlayer(self);
}
%end

%hook CADisplayLink
+ (CADisplayLink*)displayLinkWithTarget:(id)target selector:(SEL)selector {
    CADisplayLink* link = %orig;
    if (link) {
        NSString* owner = [NSString stringWithFormat:@"%@.%@", NSStringFromClass([target class]) ?: @"?",
                                                      NSStringFromSelector(selector) ?: @"?"];
        objc_setAssociatedObject(link, &NFBHeatDisplayLinkTargetKey, owner,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!NFBHeatDisplayLinks) NFBHeatDisplayLinks = [NSHashTable weakObjectsHashTable];
            [NFBHeatDisplayLinks addObject:link];
        });
    }
    return link;
}
%end

// Main thread only.
static NSString* NFBHeatMediaSummary(void) {
    NSUInteger playing = 0;
    for (AVPlayer* player in NFBHeatPlayers.allObjects) {
        if (player.rate > 0.0f) playing++;
    }
    NSCountedSet<NSString*>* owners = [NSCountedSet set];
    for (CADisplayLink* link in NFBHeatDisplayLinks.allObjects) {
        if (link.paused) continue;
        [owners addObject:objc_getAssociatedObject(link, &NFBHeatDisplayLinkTargetKey) ?: @"?"];
    }
    NSMutableArray<NSString*>* links = [NSMutableArray array];
    for (NSString* owner in owners) {
        [links addObject:[NSString stringWithFormat:@"%@x%lu", owner, (unsigned long)[owners countForObject:owner]]];
    }
    return [NSString stringWithFormat:@"video=%lu displayLinks=%lu[%@]", (unsigned long)playing,
                                      (unsigned long)owners.count,
                                      links.count ? [links componentsJoinedByString:@" "] : @"-"];
}

// MARK: - Thread CPU and stacks

typedef struct {
    uint64_t threadID;
    double seconds;
    thread_act_t port;
    char name[48];
} NFBHeatThread;

static int NFBHeatCaptureStack(thread_act_t thread, uintptr_t* frames, int maxFrames) {
    if (thread == MACH_PORT_NULL || maxFrames <= 0) return 0;
    if (thread_suspend(thread) != KERN_SUCCESS) return 0;
    // Nothing between suspend and resume may take a lock the suspended thread
    // could hold: only mach calls, no allocation, no dladdr.
    int count = 0;
    arm_thread_state64_t state;
    mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        const uintptr_t mask = 0x0000007fffffffffULL;  // strip pointer authentication bits
        uintptr_t pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(state) & mask;
        uintptr_t lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(state) & mask;
        uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(state);
        if (pc) frames[count++] = pc;
        if (lr > 0x4000 && count < maxFrames) frames[count++] = lr;
        uintptr_t previous = 0;
        while (count < maxFrames && fp && (fp & 0x7) == 0 && fp > previous) {
            struct {
                uintptr_t fp;
                uintptr_t lr;
            } record;
            vm_size_t read = 0;
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof(record),
                                  (vm_address_t)&record, &read) != KERN_SUCCESS ||
                read != sizeof(record)) {
                break;
            }
            uintptr_t frameLR = record.lr & mask;
            if (frameLR < 0x4000) break;
            frames[count++] = frameLR;
            previous = fp;
            fp = record.fp;
        }
    }
    thread_resume(thread);
    return count;
}

static NSString* NFBHeatDescribeFrames(const uintptr_t* frames, int count) {
    NSMutableString* out = [NSMutableString string];
    for (int i = 0; i < count; i++) {
        Dl_info info;
        memset(&info, 0, sizeof(info));
        const char* image = "?";
        uintptr_t offset = 0;
        if (dladdr((const void*)frames[i], &info)) {
            if (info.dli_fname) {
                const char* slash = strrchr(info.dli_fname, '/');
                image = slash ? slash + 1 : info.dli_fname;
            }
            if (info.dli_fbase) offset = frames[i] - (uintptr_t)info.dli_fbase;
        }
        [out appendFormat:@" | %s+0x%lx", image, (unsigned long)offset];
        if (info.dli_sname) [out appendFormat:@" %.60s", info.dli_sname];
    }
    return out;
}

static NSMutableDictionary<NSNumber*, NSNumber*>* NFBHeatLastThreadSeconds;  // sampler thread only

// Returns the threads sorted by CPU seconds used since the previous call; the
// caller deallocates every port in `all` after use.
static NSUInteger NFBHeatThreadDeltas(NFBHeatThread* top, NSUInteger topCapacity, double* totalSeconds,
                                      thread_act_array_t* allOut, mach_msg_type_number_t* allCount) {
    *totalSeconds = 0.0;
    *allOut = NULL;
    *allCount = 0;
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return 0;
    NSMutableDictionary<NSNumber*, NSNumber*>* seen = [NSMutableDictionary dictionary];
    NSUInteger filled = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_basic_info_data_t basic;
        mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
        thread_identifier_info_data_t ident;
        mach_msg_type_number_t identCount = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &basicCount) != KERN_SUCCESS ||
            thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &identCount) != KERN_SUCCESS) {
            continue;
        }
        double seconds = basic.user_time.seconds + basic.user_time.microseconds / 1e6 +
                         basic.system_time.seconds + basic.system_time.microseconds / 1e6;
        NSNumber* key = @(ident.thread_id);
        seen[key] = @(seconds);
        double delta = seconds - [NFBHeatLastThreadSeconds[key] doubleValue];
        if (delta <= 0.0) continue;
        *totalSeconds += delta;
        NFBHeatThread entry = {ident.thread_id, delta, threads[i], {0}};
        if (threads[i] == NFBHeatMainThread) {
            strlcpy(entry.name, "main", sizeof(entry.name));
        } else {
            pthread_t pthread = pthread_from_mach_thread_np(threads[i]);
            if (pthread) pthread_getname_np(pthread, entry.name, sizeof(entry.name));
            if (!entry.name[0]) snprintf(entry.name, sizeof(entry.name), "t%llu", ident.thread_id);
        }
        // Insertion into the short descending list.
        NSUInteger position = filled;
        while (position > 0 && top[position - 1].seconds < delta) position--;
        if (position < topCapacity) {
            NSUInteger last = filled < topCapacity ? filled : topCapacity - 1;
            for (NSUInteger k = last; k > position; k--) top[k] = top[k - 1];
            top[position] = entry;
            if (filled < topCapacity) filled++;
        }
    }
    NFBHeatLastThreadSeconds = seen;
    *allOut = threads;
    *allCount = count;
    return filled;
}

// MARK: - The periodic line

static uint64_t NFBHeatLastCounters[NFBHeatCounterCount];
static uint64_t NFBHeatLastWakeups;
static uint64_t NFBHeatLastBusyNs;
static uint64_t NFBHeatLastSampleNs;
static NSString* NFBHeatLastLine;      // main thread only
static double NFBHeatPeakCPU;          // main thread only

static void NFBHeatSample(NSString* reason) {
    @autoreleasepool {
        uint64_t now = NFBHeatNowNs();
        double window = NFBHeatLastSampleNs ? (now - NFBHeatLastSampleNs) / 1e9 : 0.0;
        NFBHeatLastSampleNs = now;

        NFBHeatThread top[4];
        memset(top, 0, sizeof(top));
        double totalSeconds = 0.0;
        thread_act_array_t threads = NULL;
        mach_msg_type_number_t threadCount = 0;
        NSUInteger topCount = NFBHeatThreadDeltas(top, 4, &totalSeconds, &threads, &threadCount);

        uint64_t wakeups = atomic_load_explicit(&NFBHeatMainWakeups, memory_order_relaxed);
        uint64_t busyNs = atomic_load_explicit(&NFBHeatMainBusyNs, memory_order_relaxed);
        uint64_t awakeSince = atomic_load_explicit(&NFBHeatMainAwakeSince, memory_order_relaxed);
        uint64_t ongoing = awakeSince && now > awakeSince ? now - awakeSince : 0;
        double wakeRate = window > 0 ? (wakeups - NFBHeatLastWakeups) / window : 0;
        double busyShare = window > 0 ? (busyNs + ongoing - NFBHeatLastBusyNs) / 1e9 / window : 0;
        NFBHeatLastWakeups = wakeups;
        NFBHeatLastBusyNs = busyNs + ongoing;

        NSMutableString* rates = [NSMutableString string];
        for (NSInteger i = 0; i < NFBHeatCounterCount; i++) {
            uint64_t value = atomic_load_explicit(&NFBHeatCounters[i], memory_order_relaxed);
            double rate = window > 0 ? (value - NFBHeatLastCounters[i]) / window : 0;
            NFBHeatLastCounters[i] = value;
            if (rate >= 0.05) [rates appendFormat:@" %s=%.1f", NFBHeatCounterNames[i], rate];
        }

        NSMutableString* threadText = [NSMutableString string];
        for (NSUInteger i = 0; i < topCount; i++) {
            [threadText appendFormat:@"%s%s %.0f%%", i ? ", " : "", top[i].name,
                                     window > 0 ? top[i].seconds / window * 100.0 : 0];
        }

        // Stack samples for a thread that used more than a third of a core.
        NSMutableArray<NSString*>* stacks = [NSMutableArray array];
        for (NSUInteger i = 0; i < topCount && stacks.count < 6; i++) {
            if (window <= 0 || top[i].seconds / window < 0.33) break;
            if (top[i].port == NFBHeatSamplerThread) continue;
            for (int sample = 0; sample < 3; sample++) {
                uintptr_t frames[40];
                int frameCount = NFBHeatCaptureStack(top[i].port, frames, 40);
                if (frameCount > 0) {
                    [stacks addObject:[NSString stringWithFormat:@"heat stack %s #%d%@", top[i].name, sample + 1,
                                                                 NFBHeatDescribeFrames(frames, frameCount)]];
                }
                usleep(60000);
            }
        }
        for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        if (threads) {
            vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_act_t));
        }

        double cpu = window > 0 ? totalSeconds / window * 100.0 : 0;
        NSString* network = NFBHeatTakeNetworkSummary();
        NSString* head = [NSString stringWithFormat:
            @"heat[%@] %.0fs cpu=%.0f%% top=%@ main busy=%.0f%% wakes=%.0f/s |%@ | net %@",
            reason, window, cpu, threadText.length ? threadText : @"-", busyShare * 100.0, wakeRate,
            rates.length ? rates : @" -", network];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProcessInfo* process = NSProcessInfo.processInfo;
            task_vm_info_data_t vm;
            mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
            double memMB = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &vmCount) == KERN_SUCCESS
                               ? vm.phys_footprint / 1048576.0
                               : -1.0;
            NSString* line = [NSString stringWithFormat:@"%@ | %@ mem=%.0fMB thermal=%ld lowPower=%d", head,
                                                        NFBHeatMediaSummary(), memMB, (long)process.thermalState,
                                                        process.isLowPowerModeEnabled ? 1 : 0];
            NFBHeatLastLine = line;
            if (cpu > NFBHeatPeakCPU) NFBHeatPeakCPU = cpu;
            NFBLogEvent(line);
            for (NSString* stack in stacks) NFBLogEvent(stack);
        });
    }
}

static void* NFBHeatSamplerMain(__unused void* arg) {
    pthread_setname_np("nfb-heat-probe");
    NFBHeatSamplerThread = mach_thread_self();
    NFBHeatSample(@"start");
    for (;;) {
        // Sleep in short steps so a thermal change can request a line at once.
        for (int step = 0; step < (int)(NFBHeatWindow * 4); step++) {
            usleep(250000);
            if (atomic_exchange_explicit(&NFBHeatWakeEarly, false, memory_order_relaxed)) break;
        }
        if (atomic_load_explicit(&NFBHeatInBackground, memory_order_relaxed)) {
            // Restart the window when the app comes back instead of averaging
            // the suspended time in.
            NFBHeatLastSampleNs = 0;
            continue;
        }
        NFBHeatSample(NFBHeatLastSampleNs ? @"30s" : @"resume");
    }
    return NULL;
}

// Main thread. For the top of the diagnostics report.
NSString* NFBHeatSummary(void) {
    return [NSString stringWithFormat:@"heat summary: peakCPU=%.0f%% last: %@", NFBHeatPeakCPU,
                                      NFBHeatLastLine ?: @"(no sample yet)"];
}

%ctor {
    %init;
    dispatch_async(dispatch_get_main_queue(), ^{
        NFBHeatMainThread = mach_thread_self();
        NFBHeatInstallRunLoopObservers();
        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                             queue:nil usingBlock:^(__unused NSNotification* note) {
            atomic_store_explicit(&NFBHeatInBackground, true, memory_order_relaxed);
        }];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
                             queue:nil usingBlock:^(__unused NSNotification* note) {
            atomic_store_explicit(&NFBHeatInBackground, false, memory_order_relaxed);
            atomic_store_explicit(&NFBHeatWakeEarly, true, memory_order_relaxed);
        }];
        [center addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil
                             queue:nil usingBlock:^(__unused NSNotification* note) {
            atomic_store_explicit(&NFBHeatWakeEarly, true, memory_order_relaxed);
        }];
        pthread_t thread;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&thread, &attr, NFBHeatSamplerMain, NULL);
        pthread_attr_destroy(&attr);
    });
}
