//go:build cgo && ios

#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

char *ledger_application_container(void) {
    @autoreleasepool {
        const char *home = [NSHomeDirectory() fileSystemRepresentation];
        if (home == NULL) return NULL;
        char *path = realpath(home, NULL);
        if (path != NULL && strlen(path) > 4096) {
            free(path);
            return NULL;
        }
        return path;
    }
}
