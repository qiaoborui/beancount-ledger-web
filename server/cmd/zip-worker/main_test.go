package main

import "testing"

func TestWorkerCountFromEnvironment(t *testing.T) {
	t.Setenv("ZIP_WORKERS", "8")

	workers, err := workerCount()
	if err != nil || workers != 8 {
		t.Fatalf("workers=%d err=%v", workers, err)
	}
}

func TestWorkerCountRejectsInvalidValue(t *testing.T) {
	t.Setenv("ZIP_WORKERS", "0")

	if _, err := workerCount(); err == nil {
		t.Fatal("expected invalid worker count to fail")
	}
}
