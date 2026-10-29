//
//  NFBHeat.h
//  NeoFreeBird
//
//  Call counters for the paths that run on every frame, cell or color lookup.
//  HeatProbe.x turns them into per-second rates in the diagnostics log, next
//  to CPU, run loop and thermal readings. One relaxed atomic add per call.
//

#import <Foundation/Foundation.h>
#import <stdatomic.h>

typedef NS_ENUM(NSInteger, NFBHeatCounter) {
    NFBHeatFeatureSwitchRead = 0,
    NFBHeatFeatureSwitchMiss,
    NFBHeatSettingsRead,
    NFBHeatSettingsMiss,
    NFBHeatViewBackgroundColor,
    NFBHeatViewMovedToWindow,
    NFBHeatColorResolve,
    NFBHeatPaletteColor,
    NFBHeatDynamicColor,
    NFBHeatPaletteRequest,
    NFBHeatFontLookup,
    NFBHeatColumnsLayout,
    NFBHeatStreamTick,
    NFBHeatStreamRefresh,
    NFBHeatNetworkResponse,
    NFBHeatCounterCount
};

#ifdef __cplusplus
extern "C" {
#endif
extern _Atomic uint64_t NFBHeatCounters[NFBHeatCounterCount];
#ifdef __cplusplus
}
#endif

static inline void NFBHeatCount(NFBHeatCounter counter) {
    atomic_fetch_add_explicit(&NFBHeatCounters[counter], 1, memory_order_relaxed);
}
