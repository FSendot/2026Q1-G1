package main

import (
	"encoding/json"
	"math"
	"testing"
)

func TestTransactionJSONContract(t *testing.T) {
	body := `{
		"transaction_id": "tx_1",
		"user_id": "user_1",
		"amount": 42.5,
		"currency": "ARS",
		"timestamp": "2026-04-03T10:22:00Z",
		"channel": "web",
		"destination_account": "dest_1",
		"country": "AR",
		"oldbalance_org": 100.0,
		"newbalance_orig": 57.5
	}`

	var tx Transaction
	if err := json.Unmarshal([]byte(body), &tx); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}
	if tx.TransactionID != "tx_1" {
		t.Fatalf("transaction_id = %q, want tx_1", tx.TransactionID)
	}
	if tx.UserID != "user_1" {
		t.Fatalf("user_id = %q, want user_1", tx.UserID)
	}
	if tx.OldBalanceOrg == nil || *tx.OldBalanceOrg != 100.0 {
		t.Fatalf("oldbalance_org = %v, want 100", tx.OldBalanceOrg)
	}
	if tx.NewBalanceOrig == nil || *tx.NewBalanceOrig != 57.5 {
		t.Fatalf("newbalance_orig = %v, want 57.5", tx.NewBalanceOrig)
	}
}

func TestBuildMLFeaturesInitializesContractFields(t *testing.T) {
	oldBalance := 100.0
	newBalance := 57.5
	tx := Transaction{
		TransactionID:  "tx_1",
		Amount:         42.5,
		OldBalanceOrg:  &oldBalance,
		NewBalanceOrig: &newBalance,
	}

	features := buildMLFeatures(tx, []string{
		"amount",
		"amount_log1p",
		"oldbalance_org",
		"newbalance_orig",
		"balance_delta_org",
		"card1",
	})

	if got := features["amount"]; got != 42.5 {
		t.Fatalf("amount = %v, want 42.5", got)
	}
	if got := features["oldbalance_org"]; got != 100.0 {
		t.Fatalf("oldbalance_org = %v, want 100", got)
	}
	if got := features["balance_delta_org"]; got != -42.5 {
		t.Fatalf("balance_delta_org = %v, want -42.5", got)
	}
	if value := features["card1"]; !math.IsNaN(value) {
		t.Fatalf("card1 = %v, want NaN placeholder", value)
	}
}
