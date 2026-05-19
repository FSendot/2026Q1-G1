package writer

import (
	"strings"
	"testing"
	"time"
)

func TestDecodeRecordBodyRawJSON(t *testing.T) {
	t.Parallel()

	row, err := decodeRecordBody(`{"transaction_id":"tx-1","user_id":"user-1","is_fraud":true}`)
	if err != nil {
		t.Fatalf("decodeRecordBody() error = %v", err)
	}

	if row.TransactionID != "tx-1" {
		t.Fatalf("TransactionID = %q, want tx-1", row.TransactionID)
	}
	if row.UserID == nil || *row.UserID != "user-1" {
		t.Fatalf("UserID = %#v, want user-1", row.UserID)
	}
	if row.IsFraud == nil || !*row.IsFraud {
		t.Fatalf("IsFraud = %#v, want true", row.IsFraud)
	}
}

func TestDecodeRecordBodySNSWrapper(t *testing.T) {
	t.Parallel()

	row, err := decodeRecordBody(`{"Type":"Notification","Message":"{\"transaction_id\":\"tx-2\",\"amount\":12.5,\"currency\":\"ARS\"}"}`)
	if err != nil {
		t.Fatalf("decodeRecordBody() error = %v", err)
	}

	if row.TransactionID != "tx-2" {
		t.Fatalf("TransactionID = %q, want tx-2", row.TransactionID)
	}
	if row.Amount == nil || *row.Amount != 12.5 {
		t.Fatalf("Amount = %#v, want 12.5", row.Amount)
	}
	if row.Currency == nil || *row.Currency != "ARS" {
		t.Fatalf("Currency = %#v, want ARS", row.Currency)
	}
}

func TestBuildInsertStatementChunksRows(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.May, 18, 12, 0, 0, 0, time.UTC)
	user := "user-1"
	currency := "USD"
	rows := []payload{
		{
			TransactionID: "tx-1",
			UserID:        &user,
			Currency:      &currency,
			IsFraud:       boolPtr(true),
			ProcessedAt:   &now,
		},
		{
			TransactionID: "tx-2",
			IsFraud:       boolPtr(false),
		},
	}

	query, args := buildInsertStatement(rows)

	if !strings.HasPrefix(query, "INSERT INTO transactions (transaction_id, user_id, amount, currency, country, channel, fraud_score, is_fraud, decision, processed_at) VALUES ") {
		t.Fatalf("query prefix mismatch: %s", query)
	}
	if !strings.HasSuffix(query, "ON CONFLICT (transaction_id) DO NOTHING") {
		t.Fatalf("query suffix mismatch: %s", query)
	}
	if got, want := len(args), 20; got != want {
		t.Fatalf("len(args) = %d, want %d", got, want)
	}
	if got, want := args[8], "block"; got != want {
		t.Fatalf("decision arg 1 = %v, want %v", got, want)
	}
	if got, want := args[18], "allow"; got != want {
		t.Fatalf("decision arg 2 = %v, want %v", got, want)
	}
}

func boolPtr(value bool) *bool {
	return &value
}
