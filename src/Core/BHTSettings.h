//
//  BHTSettings.h
//  NeoFreeBird
//
//  Created by nyaathea
//

#import <Foundation/Foundation.h>

// Single source of truth for every user setting: per-page toggle lists,
// page titles and the default value used when a key was never toggled.
@interface BHTSettings : NSObject

+ (NSArray<NSDictionary*>*)settingsForPage:(NSString*)pageKey;
+ (NSString*)titleKeyForPage:(NSString*)pageKey;
+ (NSString*)subtitleKeyForPage:(NSString*)pageKey;
+ (NSDictionary*)settingForKey:(NSString*)key;

// Every NSUserDefaults key the registry owns, for bulk work like the settings
// export. Rows that only push another screen have no preference behind them and
// are left out.
+ (NSArray<NSString*>*)allPreferenceKeys;
+ (BOOL)boolForKey:(NSString*)key;
+ (NSInteger)integerForKey:(NSString*)key;

@end

// Bumped whenever NSUserDefaults changes in this process. Hot-path caches of
// values derived from settings compare against it to know when to recompute.
#ifdef __cplusplus
extern "C" {
#endif
uint64_t BHTDefaultsGeneration(void);
#ifdef __cplusplus
}
#endif
