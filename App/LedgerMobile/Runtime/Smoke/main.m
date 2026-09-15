#import <Foundation/Foundation.h>
#include "BeancountRuntime.h"

int main(void) {
    @autoreleasepool {
        char *failure = BRInitialize(NSBundle.mainBundle.bundlePath.UTF8String);
        if (failure) { fprintf(stderr, "INIT FAILED: %s\n", failure); BRFree(failure); return 1; }
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSArray<NSString *> *ledgers = @[
            @"2000-01-01 open Assets:Cash CNY\n2000-01-01 open Expenses:Food CNY\n2026-01-01 * \"Lunch\"\n  Assets:Cash -10 CNY\n  Expenses:Food 10 CNY\n",
            @"2000-01-01 open Assets:Cash CNY\n2000-01-01 open Expenses:Food CNY\n2026-01-01 * \"Lunch\"\n  Assets:Cash -10 CNY\n  Expenses:Food 9 CNY\n",
            @"plugin \"os\"\n",
            @"include \"../outside.bean\"\n",
            @"2000-01-01 open Assets:Cash CNY\n2000-01-02 balance Assets:Cash 1 CNY\n"
        ];
        NSMutableArray *results = [NSMutableArray array];
        for (NSUInteger index = 0; index < ledgers.count; index++) {
            [ledgers[index] writeToFile:[root stringByAppendingPathComponent:@"main.bean"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            char *json = BRValidate(root.UTF8String, "main.bean");
            if (!json) return 2;
            NSDictionary *result = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            BRFree(json);
            NSArray *errors = result[@"errors"];
            BOOL passed = errors != nil && ((index == 0) == (errors.count == 0));
            [results addObject:@{@"case": @(index), @"passed": @(passed), @"result": result ?: @{}}];
        }
        NSData *report = [NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        [report writeToFile:[documents stringByAppendingPathComponent:@"runtime-smoke.json"] atomically:YES];
        fprintf(stdout, "%s\n", [[NSString alloc] initWithData:report encoding:NSUTF8StringEncoding].UTF8String);
        return [results filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"passed == NO"]].count ? 3 : 0;
    }
}
