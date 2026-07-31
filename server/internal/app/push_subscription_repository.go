package app

import (
	"context"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent/webpushsubscription"
)

// pushSubscriptionRepository provides row-level operations for browser
// subscriptions. It deliberately exposes the domain entity rather than a
// generic JSON document.
type pushSubscriptionRepository interface {
	List(context.Context) ([]StoredPushSubscription, error)
	Save(context.Context, StoredPushSubscription) (StoredPushSubscription, int, error)
	Backfill(context.Context, []StoredPushSubscription) error
	DeleteEndpoints(context.Context, []string) (int, int, error)
	Count(context.Context) (int, error)
}

type entPushSubscriptionRepository struct {
	client *ent.Client
}

func newEntPushSubscriptionRepository(client *ent.Client) pushSubscriptionRepository {
	if client == nil {
		return nil
	}
	return &entPushSubscriptionRepository{client: client}
}

func (r *entPushSubscriptionRepository) List(ctx context.Context) ([]StoredPushSubscription, error) {
	rows, err := r.client.WebPushSubscription.Query().Order(ent.Asc(webpushsubscription.FieldCreatedAt)).All(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]StoredPushSubscription, 0, len(rows))
	for _, row := range rows {
		out = append(out, pushSubscriptionFromEnt(row))
	}
	return out, nil
}

func (r *entPushSubscriptionRepository) Save(ctx context.Context, subscription StoredPushSubscription) (StoredPushSubscription, int, error) {
	createdAt, err := time.Parse(time.RFC3339Nano, subscription.CreatedAt)
	if err != nil {
		return StoredPushSubscription{}, 0, err
	}
	updatedAt, err := time.Parse(time.RFC3339Nano, subscription.UpdatedAt)
	if err != nil {
		return StoredPushSubscription{}, 0, err
	}
	create := r.client.WebPushSubscription.Create().
		SetID(subscription.ID).
		SetEndpoint(subscription.Subscription.Endpoint).
		SetAuthSecret(subscription.Subscription.Keys.Auth).
		SetP256dh(subscription.Subscription.Keys.P256dh).
		SetUserAgent(subscription.UserAgent).
		SetCreatedAt(createdAt).
		SetUpdatedAt(updatedAt)
	if subscription.Subscription.ExpirationTime != nil {
		create.SetExpirationTime(*subscription.Subscription.ExpirationTime)
	}
	upsert := create.OnConflictColumns(webpushsubscription.FieldEndpoint).
		SetAuthSecret(subscription.Subscription.Keys.Auth).
		SetP256dh(subscription.Subscription.Keys.P256dh).
		SetUserAgent(subscription.UserAgent).
		SetUpdatedAt(updatedAt)
	if subscription.Subscription.ExpirationTime == nil {
		upsert.ClearExpirationTime()
	} else {
		upsert.SetExpirationTime(*subscription.Subscription.ExpirationTime)
	}
	if err := upsert.Exec(ctx); err != nil {
		return StoredPushSubscription{}, 0, err
	}
	row, err := r.client.WebPushSubscription.Query().Where(webpushsubscription.EndpointEQ(subscription.Subscription.Endpoint)).Only(ctx)
	if err != nil {
		return StoredPushSubscription{}, 0, err
	}
	count, err := r.Count(ctx)
	if err != nil {
		return StoredPushSubscription{}, 0, err
	}
	return pushSubscriptionFromEnt(row), count, nil
}

func (r *entPushSubscriptionRepository) Backfill(ctx context.Context, subscriptions []StoredPushSubscription) error {
	for _, subscription := range subscriptions {
		createdAt, err := time.Parse(time.RFC3339Nano, subscription.CreatedAt)
		if err != nil {
			return err
		}
		updatedAt, err := time.Parse(time.RFC3339Nano, subscription.UpdatedAt)
		if err != nil {
			return err
		}
		create := r.client.WebPushSubscription.Create().
			SetID(subscription.ID).
			SetEndpoint(subscription.Subscription.Endpoint).
			SetAuthSecret(subscription.Subscription.Keys.Auth).
			SetP256dh(subscription.Subscription.Keys.P256dh).
			SetUserAgent(subscription.UserAgent).
			SetCreatedAt(createdAt).
			SetUpdatedAt(updatedAt)
		if subscription.Subscription.ExpirationTime != nil {
			create.SetExpirationTime(*subscription.Subscription.ExpirationTime)
		}
		if err := create.OnConflictColumns(webpushsubscription.FieldEndpoint).DoNothing().Exec(ctx); err != nil {
			return err
		}
	}
	return nil
}

func (r *entPushSubscriptionRepository) DeleteEndpoints(ctx context.Context, endpoints []string) (int, int, error) {
	if len(endpoints) == 0 {
		count, err := r.Count(ctx)
		return 0, count, err
	}
	removed, err := r.client.WebPushSubscription.Delete().Where(webpushsubscription.EndpointIn(endpoints...)).Exec(ctx)
	if err != nil {
		return 0, 0, err
	}
	count, err := r.Count(ctx)
	return removed, count, err
}

func (r *entPushSubscriptionRepository) Count(ctx context.Context) (int, error) {
	return r.client.WebPushSubscription.Query().Count(ctx)
}

func pushSubscriptionFromEnt(row *ent.WebPushSubscription) StoredPushSubscription {
	if row == nil {
		return StoredPushSubscription{}
	}
	return StoredPushSubscription{
		ID: row.ID,
		Subscription: PushSubscription{
			Endpoint:       row.Endpoint,
			ExpirationTime: row.ExpirationTime,
			Keys:           PushSubscriptionKey{Auth: row.AuthSecret, P256dh: row.P256dh},
		},
		UserAgent: row.UserAgent,
		CreatedAt: row.CreatedAt.UTC().Format(time.RFC3339Nano),
		UpdatedAt: row.UpdatedAt.UTC().Format(time.RFC3339Nano),
	}
}

var _ pushSubscriptionRepository = (*entPushSubscriptionRepository)(nil)
