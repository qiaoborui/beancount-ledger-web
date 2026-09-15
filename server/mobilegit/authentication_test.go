package mobilegit

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/go-git/go-git/v5/plumbing/transport"
)

func TestAuthenticationErrorsHaveStableCodesForAutomaticRetryPolicy(t *testing.T) {
	for _, test := range []struct {
		err  error
		code string
	}{
		{transport.ErrAuthenticationRequired, "git.authentication"},
		{transport.ErrAuthorizationFailed, "git.authorization"},
	} {
		t.Run(test.code, func(t *testing.T) {
			var decoded response
			if err := json.Unmarshal([]byte(encodeFailure(request{}, fmt.Errorf("fetch: %w", test.err))), &decoded); err != nil {
				t.Fatal(err)
			}
			if decoded.Error == nil || decoded.Error.Code != test.code {
				t.Fatalf("unexpected authentication response: %+v", decoded.Error)
			}
		})
	}
}
