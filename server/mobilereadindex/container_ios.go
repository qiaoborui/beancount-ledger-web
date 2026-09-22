//go:build cgo && ios

package mobilereadindex

/*
#cgo LDFLAGS: -framework Foundation
#include <stdlib.h>
char *ledger_application_container(void);
*/
import "C"

import "unsafe"

// The boundary comes from Foundation, never from bridge request parameters.
// Failure retains the strict host ancestor policy.
func applicationContainer() string {
	path := C.ledger_application_container()
	if path == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(path))
	return C.GoString(path)
}
