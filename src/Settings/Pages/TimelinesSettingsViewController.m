//
//  TimelinesSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/TimelinesSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"
#import "Headers/TWHeaders.h"
#import "CustomTabBar/CustomTabBarUtility.h"

extern void applyHideCustomTimelinesSetting(void);
extern void NFBStreamPrefsChanged(void);
extern void NFBColumnsPrefsChanged(void);
extern void NFBColumnsShowManager(UIViewController* presenter);

@implementation TimelinesSettingsViewController

- (NSString*)pageKey {
    return @"timelines";
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if ([key isEqualToString:@"hide_custom_timelines"]) {
        applyHideCustomTimelinesSetting();
    } else if ([key isEqualToString:@"auto_stream_timeline"]) {
        NFBStreamPrefsChanged();
    } else if ([key isEqualToString:@"nfb_columns_enabled"] || [key isEqualToString:@"nfb_columns_full_width"]) {
        NFBColumnsPrefsChanged();
    }
}

- (void)showColumnsManager:(NSDictionary*)sender {
    NFBColumnsShowManager(self);
}

// Which bottom tab becomes the Columns tab. Offers every tab the app has built (as recorded by
// the custom tab bar), except Home and the "more" dash.
- (void)showColumnsHostPicker:(NSDictionary*)sender {
    BHTBundle* bundle = [BHTBundle sharedBundle];
    NSString* current = [[NSUserDefaults standardUserDefaults] stringForKey:@"nfb_columns_host"] ?: @"communities";
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"NFB_COLUMNS_HOST_PICKER_TITLE"]
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    for (NSDictionary* tab in [CustomTabBarUtility availableTabs]) {
        NSString* page = tab[TabPageKey];
        if (!page.length || [page isEqualToString:CustomTabBarHomePageID] || [page isEqualToString:@"dash"]) continue;
        NSString* title = [tab[TabTitleKey] length] ? tab[TabTitleKey] : page;
        if ([page isEqualToString:current]) title = [@"✓ " stringByAppendingString:title];
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [[NSUserDefaults standardUserDefaults] setObject:page forKey:@"nfb_columns_host"];
                                                    NFBColumnsPrefsChanged();
                                                    [self.tableView reloadData];
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Same choices as the stream button's long-press menu; applies immediately.
- (void)showAutoStreamIntervalPicker:(NSDictionary*)sender {
    NSInteger current = [BHTSettings integerForKey:@"auto_stream_interval"];
    if (current < 5) current = 20;
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"NFB_INTERVAL_PICKER_TITLE"]
                         message:[NSString stringWithFormat:[bundle localizedStringForKey:@"NFB_INTERVAL_CURRENT"], (long)current]
                  preferredStyle:UIAlertControllerStyleAlert];
    for (NSNumber* seconds in @[@5, @10, @15, @20, @30, @60]) {
        NSString* label = [NSString stringWithFormat:[bundle localizedStringForKey:@"NFB_SECONDS_FMT"], (long)seconds.integerValue];
        [alert addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [[NSUserDefaults standardUserDefaults]
                                                        setInteger:seconds.integerValue
                                                            forKey:@"auto_stream_interval"];
                                                    NFBStreamPrefsChanged();
                                                    [self.tableView reloadData];
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
