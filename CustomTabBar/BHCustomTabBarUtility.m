//
//  BHCustomTabBarUtility.m
//  BHTwitter
//
//  Created by Bandar Alruwaili on 10/12/2023.
//

#import "BHCustomTabBarUtility.h"

static NSArray<BHCustomTabBarItem *> *BHCustomTabBarItemsForKey(NSString *key) {
    NSData *savedItems = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (!savedItems) return nil;
    return [NSKeyedUnarchiver unarchiveObjectWithData:savedItems];
}

static BOOL BHCustomTabBarItemsContainPageID(NSArray<BHCustomTabBarItem *> *items, NSString *pageID) {
    for (BHCustomTabBarItem *item in items) {
        if ([item.pageID isEqualToString:pageID]) return YES;
    }
    return NO;
}

@implementation BHCustomTabBarUtility
+ (NSArray<NSString *> *)getAllowedTabBars {
    NSArray<BHCustomTabBarItem *> *savedList = BHCustomTabBarItemsForKey(@"allowed");
    if (savedList) {
        NSMutableArray<NSString *> *tmpArr = [NSMutableArray array];
        for (BHCustomTabBarItem *item in savedList) {
            [tmpArr addObject:item.pageID];
        }
        if ([tmpArr containsObject:@"media"]) {
            [tmpArr removeObject:@"media"];
            if (![tmpArr containsObject:@"communities"]) [tmpArr addObject:@"communities"];
        }
        return tmpArr;
    }
    return nil;
}

+ (NSArray<NSString *> *)getHiddenTabBars {
    NSArray<BHCustomTabBarItem *> *savedList = BHCustomTabBarItemsForKey(@"hidden");
    if (savedList) {
        NSMutableArray<NSString *> *tmpArr = [NSMutableArray array];
        for (BHCustomTabBarItem *item in savedList) {
            [tmpArr addObject:item.pageID];
        }
        NSArray<BHCustomTabBarItem *> *allowedList = BHCustomTabBarItemsForKey(@"allowed");
        if (BHCustomTabBarItemsContainPageID(allowedList, @"media")) {
            [tmpArr removeObject:@"communities"];
            if (![tmpArr containsObject:@"media"]) [tmpArr addObject:@"media"];
        }
        return tmpArr;
    }
    return nil;
}
@end
