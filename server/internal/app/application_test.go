package app

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/gin-gonic/gin"
)

type applicationTestCloser struct {
	id     string
	closed *[]string
	err    error
}

func (c *applicationTestCloser) Close() error {
	*c.closed = append(*c.closed, c.id)
	return c.err
}

func TestNewApplicationServesExistingRouterContract(t *testing.T) {
	application, err := NewApplication(testLedger(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := application.Close(); err != nil {
			t.Error(err)
		}
	})

	response := httptest.NewRecorder()
	application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/health", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("health status = %d body=%s", response.Code, response.Body.String())
	}
	if application.router == nil {
		t.Fatal("application router is nil")
	}
}

func TestApplicationCloseClosesResourcesOnceInReverseOrder(t *testing.T) {
	closed := []string{}
	application := newApplication(gin.New(), []io.Closer{
		&applicationTestCloser{id: "database", closed: &closed},
		&applicationTestCloser{id: "index", closed: &closed},
	})

	if err := application.Close(); err != nil {
		t.Fatal(err)
	}
	if err := application.Close(); err != nil {
		t.Fatal(err)
	}
	if want := []string{"index", "database"}; !reflect.DeepEqual(closed, want) {
		t.Fatalf("closed resources = %v, want %v", closed, want)
	}
}

func TestApplicationCloseJoinsResourceErrors(t *testing.T) {
	firstErr := errors.New("first close failed")
	secondErr := errors.New("second close failed")
	closed := []string{}
	application := newApplication(gin.New(), []io.Closer{
		&applicationTestCloser{id: "first", closed: &closed, err: firstErr},
		&applicationTestCloser{id: "second", closed: &closed, err: secondErr},
	})

	err := application.Close()
	if !errors.Is(err, firstErr) || !errors.Is(err, secondErr) {
		t.Fatalf("Close error = %v, want both resource errors", err)
	}
}
