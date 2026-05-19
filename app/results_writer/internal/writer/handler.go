package writer

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	transactionInsertColumns = "transaction_id, user_id, amount, currency, country, channel, fraud_score, is_fraud, decision, processed_at"
	maxRowsPerStatement      = 5000
)

const schemaSQL = `
CREATE TABLE IF NOT EXISTS transactions (
    id             SERIAL PRIMARY KEY,
    transaction_id VARCHAR(255) UNIQUE NOT NULL,
    user_id        VARCHAR(255),
    amount         NUMERIC(15, 2),
    currency       VARCHAR(10),
    country        VARCHAR(100),
    channel        VARCHAR(50),
    fraud_score    FLOAT,
    is_fraud       BOOLEAN,
    decision       VARCHAR(20),
    processed_at   TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tx_processed_at ON transactions (processed_at DESC);
CREATE INDEX IF NOT EXISTS idx_tx_is_fraud     ON transactions (is_fraud);
CREATE INDEX IF NOT EXISTS idx_tx_user_id      ON transactions (user_id);
`

type Event struct {
	Records []Record `json:"Records"`
}

type Record struct {
	Body string `json:"body"`
}

type Result struct {
	Processed int `json:"processed"`
}

type payload struct {
	TransactionID string     `json:"transaction_id"`
	UserID        *string    `json:"user_id,omitempty"`
	Amount        *float64   `json:"amount,omitempty"`
	Currency      *string    `json:"currency,omitempty"`
	Country       *string    `json:"country,omitempty"`
	Channel       *string    `json:"channel,omitempty"`
	FraudScore    *float64   `json:"fraud_score,omitempty"`
	IsFraud       *bool      `json:"is_fraud,omitempty"`
	ProcessedAt   *time.Time `json:"processed_at,omitempty"`
}

func Handle(ctx context.Context, db *sql.DB, event Event) (Result, error) {
	if len(event.Records) == 0 {
		return Result{Processed: 0}, nil
	}

	rows := make([]payload, 0, len(event.Records))
	for idx, record := range event.Records {
		row, err := decodeRecordBody(record.Body)
		if err != nil {
			return Result{}, fmt.Errorf("record %d: %w", idx, err)
		}
		rows = append(rows, row)
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return Result{}, fmt.Errorf("begin transaction: %w", err)
	}
	defer func() {
		_ = tx.Rollback()
	}()

	if _, err := tx.ExecContext(ctx, schemaSQL); err != nil {
		return Result{}, fmt.Errorf("ensure schema: %w", err)
	}

	if err := insertRows(ctx, tx, rows); err != nil {
		return Result{}, err
	}

	if err := tx.Commit(); err != nil {
		return Result{}, fmt.Errorf("commit transaction: %w", err)
	}

	return Result{Processed: len(rows)}, nil
}

func decodeRecordBody(body string) (payload, error) {
	if maybeSNS, ok := unwrapSNSBody(body); ok {
		body = maybeSNS
	}

	var row payload
	if err := json.Unmarshal([]byte(body), &row); err != nil {
		return payload{}, fmt.Errorf("decode JSON body: %w", err)
	}
	if row.TransactionID == "" {
		return payload{}, errors.New("transaction_id is required")
	}

	return row, nil
}

func unwrapSNSBody(body string) (string, bool) {
	var envelope struct {
		Message string `json:"Message"`
	}
	if err := json.Unmarshal([]byte(body), &envelope); err != nil {
		return "", false
	}
	if envelope.Message == "" {
		return "", false
	}

	return envelope.Message, true
}

func insertRows(ctx context.Context, tx *sql.Tx, rows []payload) error {
	for start := 0; start < len(rows); start += maxRowsPerStatement {
		end := start + maxRowsPerStatement
		if end > len(rows) {
			end = len(rows)
		}

		query, args := buildInsertStatement(rows[start:end])
		if _, err := tx.ExecContext(ctx, query, args...); err != nil {
			return fmt.Errorf("insert rows %d-%d: %w", start, end, err)
		}
	}

	return nil
}

func buildInsertStatement(rows []payload) (string, []any) {
	var b strings.Builder
	b.Grow(len(rows) * 96)

	b.WriteString("INSERT INTO transactions (")
	b.WriteString(transactionInsertColumns)
	b.WriteString(") VALUES ")

	args := make([]any, 0, len(rows)*10)
	for idx, row := range rows {
		if idx > 0 {
			b.WriteByte(',')
		}

		base := idx*10 + 1
		b.WriteString("(")
		b.WriteString("$")
		b.WriteString(strconv.Itoa(base))
		b.WriteString(", $")
		b.WriteString(strconv.Itoa(base + 1))
		b.WriteString(", $")
		b.WriteString(strconv.Itoa(base + 2))
		b.WriteString(", $")
		b.WriteString(strconv.Itoa(base + 3))
		b.WriteString(", $")
		b.WriteString(strconv.Itoa(base + 4))
		b.WriteString(", $")
		b.WriteString(strconv.Itoa(base + 5))
		b.WriteString(", $")
		b.WriteString(strconv.Itoa(base + 6))
		b.WriteString(", $")
		b.WriteString(strconv.Itoa(base + 7))
		b.WriteString(", $")
		b.WriteString(strconv.Itoa(base + 8))
		b.WriteString(", COALESCE($")
		b.WriteString(strconv.Itoa(base + 9))
		b.WriteString("::timestamptz, NOW()))")

		args = append(args,
			row.TransactionID,
			nullableString(row.UserID),
			nullableFloat64(row.Amount),
			nullableString(row.Currency),
			nullableString(row.Country),
			nullableString(row.Channel),
			nullableFloat64(row.FraudScore),
			boolValue(row.IsFraud),
			decisionValue(row.IsFraud),
			nullableTime(row.ProcessedAt),
		)
	}

	b.WriteString(" ON CONFLICT (transaction_id) DO NOTHING")

	return b.String(), args
}

func nullableString(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func nullableFloat64(value *float64) any {
	if value == nil {
		return nil
	}
	return *value
}

func nullableTime(value *time.Time) any {
	if value == nil {
		return nil
	}
	return *value
}

func boolValue(value *bool) bool {
	if value == nil {
		return false
	}
	return *value
}

func decisionValue(isFraud *bool) string {
	if boolValue(isFraud) {
		return "block"
	}
	return "allow"
}
