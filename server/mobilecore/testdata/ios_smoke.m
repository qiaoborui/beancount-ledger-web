#import <Foundation/Foundation.h>
#import <LedgerCore/Mobilecore.objc.h>

static NSDictionary *decode(NSString *json) {
    return [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                          options:0 error:NULL];
}

int main(void) {
    @autoreleasepool {
        NSString *request = @"{\"version\":1,\"filename\":\"smoke.bean\",\"text\":\"2026-09-15 * \\\"Coffee\\\"\\n  Expenses:Food 10 CNY\\n  Assets:Cash -9 CNY\"}";
        NSDictionary *parsed = decode(MobilecoreParseTextJSON(request));
        NSDictionary *compiled = decode(MobilecoreCompileTextJSON(request));
        if (![parsed[@"ok"] boolValue] || [compiled[@"ok"] boolValue]) return 1;
        NSArray *errors = compiled[@"diagnostics"];
        if (errors.count != 1 || ![errors[0][@"code"] isEqual:@"beancount.balance_error"]) return 2;

        NSDictionary *workspaceRequest = @{
            @"version": @1,
            @"entrypoint": @"main.bean",
            @"files": @[
                @{ @"path": @"main.bean", @"text": @"include \"transactions/day.bean\"" },
                @{ @"path": @"transactions/day.bean", @"text": @"2026-09-15 * \"Coffee\"\n  Expenses:Food 10 CNY\n  Assets:Cash -9 CNY" }
            ]
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:workspaceRequest options:0 error:NULL];
        NSDictionary *workspace = decode(MobilecoreCompileWorkspaceJSON([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]));
        NSArray *workspaceErrors = workspace[@"diagnostics"];
        if ([workspace[@"ok"] boolValue] || workspaceErrors.count != 1) return 3;
        if (![workspaceErrors[0][@"file"] isEqual:@"transactions/day.bean"] ||
            ![workspaceErrors[0][@"code"] isEqual:@"beancount.balance_error"] ||
            [workspaceErrors[0][@"line"] intValue] != 1) return 4;
        puts("PASS: iOS Simulator Objective-C -> Go parse, compile, and include-aware diagnostics");
    }
    return 0;
}
