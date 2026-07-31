package app

import (
	"context"
	"testing"
	"time"
)

func TestRuntimeGmailStateRepositoryRoundTrip(t *testing.T) {
	cfg := testLedger(t)
	repository := newRuntimeGmailStateRepository(newFilesystemRuntimeStore(cfg.RuntimeDir))
	ctx := context.Background()
	now := time.Now().UTC().Format(time.RFC3339Nano)

	connection := gmailConnection{Email: "owner@example.com", EncryptedRefreshToken: "encrypted", LabelID: "label", LabelName: "Bills", HistoryID: 18446744073709551615, ConnectedAt: now, UpdatedAt: now}
	if err := repository.SaveConnection(ctx, connection); err != nil {
		t.Fatal(err)
	}
	storedConnection, ok, err := repository.Connection(ctx)
	if err != nil || !ok || storedConnection.HistoryID != connection.HistoryID {
		t.Fatalf("connection=%#v ok=%v err=%v", storedConnection, ok, err)
	}

	oauth := gmailOAuthState{Value: "csrf", ExpiresAt: now}
	if err := repository.SaveOAuthState(ctx, oauth); err != nil {
		t.Fatal(err)
	}
	storedOAuth, ok, err := repository.OAuthState(ctx)
	if err != nil || !ok || storedOAuth != oauth {
		t.Fatalf("oauth=%#v ok=%v err=%v", storedOAuth, ok, err)
	}

	pushes := gmailPushEventStore{Items: []gmailPushEvent{{ID: "push-1", Email: "owner@example.com", HistoryID: connection.HistoryID, Status: "queued", AvailableAt: now, CreatedAt: now, UpdatedAt: now}}}
	if err := repository.SavePushEvents(ctx, pushes); err != nil {
		t.Fatal(err)
	}
	storedPushes, err := repository.PushEvents(ctx)
	if err != nil || len(storedPushes.Items) != 1 || storedPushes.Items[0].HistoryID != connection.HistoryID {
		t.Fatalf("pushes=%#v err=%v", storedPushes, err)
	}

	pending := gmailPendingStore{Items: []GmailPendingImport{{ID: "pending-1", ImportID: "import-1", SourceKey: "source-1", MessageID: "message-1", Filename: "bill.csv", Status: "ready", CreatedAt: now, UpdatedAt: now}}}
	if err := repository.SavePending(ctx, pending); err != nil {
		t.Fatal(err)
	}
	storedPending, err := repository.Pending(ctx)
	if err != nil || len(storedPending.Items) != 1 || storedPending.Items[0].SourceKey != "source-1" {
		t.Fatalf("pending=%#v err=%v", storedPending, err)
	}

	lease := gmailSyncLease{Owner: "worker", ExpiresAt: now}
	if err := repository.SaveSyncLease(ctx, lease); err != nil {
		t.Fatal(err)
	}
	storedLease, ok, err := repository.SyncLease(ctx)
	if err != nil || !ok || storedLease != lease {
		t.Fatalf("lease=%#v ok=%v err=%v", storedLease, ok, err)
	}
}

func TestGmailRuntimeBackfillCapturesMalformedLegacyState(t *testing.T) {
	cfg := testLedger(t)
	runtime := newFilesystemRuntimeStore(cfg.RuntimeDir)
	if err := runtime.PutJSON(context.Background(), "gmail", gmailConnectionKey, map[string]any{"connectedAt": "not-a-time"}); err != nil {
		t.Fatal(err)
	}
	// The startup bridge must surface malformed data rather than quietly losing
	// it. A fake persistence store is intentionally unnecessary here: Ent's
	// backfill parser is exercised directly.
	repository := &entGmailStateRepository{}
	if err := repository.Backfill(context.Background(), gmailLegacyState{Connection: &gmailConnection{ConnectedAt: "not-a-time"}}); err == nil {
		t.Fatal("expected malformed time error")
	}
}
