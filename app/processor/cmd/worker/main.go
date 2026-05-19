package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"strconv"
	"sync"
	"time"

	fraudruntime "github.com/FSendot/fraud-detector/net/serving/go/pkg/fraudruntime"
	"github.com/FSendot/fraud-detector/processor/internal/dynamo"
	"github.com/FSendot/fraud-detector/processor/internal/scoring"
	"github.com/FSendot/fraud-detector/processor/internal/store"
	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	dynamosvc "github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	sqstypes "github.com/aws/aws-sdk-go-v2/service/sqs/types"
)

// Transaction is the JSON payload expected from the SQS queue.
// Balance fields are optional: when absent the ML engine applies its
// MissingGoToLeft strategy for those tree splits.
// Features allows callers to supply pre-computed ML features (e.g. card/addr/velocity
// signals). Values override NaN defaults for known feature-contract names; unknown
// names are silently ignored.
type Transaction struct {
	TransactionID      string             `json:"transaction_id"`
	UserID             string             `json:"user_id"`
	Amount             float64            `json:"amount"`
	Currency           string             `json:"currency"`
	Timestamp          string             `json:"timestamp"`
	Channel            string             `json:"channel"`
	DestinationAccount string             `json:"destination_account"`
	Country            string             `json:"country"`
	OldBalanceOrg      *float64           `json:"oldbalance_org,omitempty"`
	NewBalanceOrig     *float64           `json:"newbalance_orig,omitempty"`
	OldBalanceDest     *float64           `json:"oldbalance_dest,omitempty"`
	NewBalanceDest     *float64           `json:"newbalance_dest,omitempty"`
	Features           map[string]float64 `json:"features,omitempty"`
}

// ScoringResult is published to the results queues after scoring.
type ScoringResult struct {
	TransactionID string  `json:"transaction_id"`
	UserID        string  `json:"user_id"`
	Amount        float64 `json:"amount"`
	Currency      string  `json:"currency"`
	Country       string  `json:"country"`
	Channel       string  `json:"channel"`
	FraudScore    float64 `json:"fraud_score"`
	IsFraud       bool    `json:"is_fraud"`
	ProcessedAt   string  `json:"processed_at,omitempty"`
}

// AuditEvent is written to S3 for full traceability.
type AuditEvent struct {
	Transaction   Transaction   `json:"transaction"`
	ScoringResult ScoringResult `json:"scoring_result"`
	ProcessedAt   string        `json:"processed_at"`
}

type userLockSet struct {
	locks sync.Map
}

func (s *userLockSet) lock(userID string) func() {
	value, _ := s.locks.LoadOrStore(userID, &sync.Mutex{})
	mu := value.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}

// scorer abstracts ML engine and rule-based fallback behind a single interface.
type scorer interface {
	score(ctx context.Context, tx Transaction, profile *dynamo.UserProfile) (fraudScore float64, isFraud bool)
}

type queueClient interface {
	ReceiveMessage(ctx context.Context, params *sqs.ReceiveMessageInput, optFns ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error)
	DeleteMessage(ctx context.Context, params *sqs.DeleteMessageInput, optFns ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error)
	SendMessage(ctx context.Context, params *sqs.SendMessageInput, optFns ...func(*sqs.Options)) (*sqs.SendMessageOutput, error)
}

type profileStore interface {
	GetProfile(ctx context.Context, userID string) (*dynamo.UserProfile, error)
	UpdateProfile(ctx context.Context, profile *dynamo.UserProfile, amount float64, country, channel, destination, timestamp string) error
}

// mlScorer uses the trained Go runtime loaded from runtime_spec.json.
type mlScorer struct {
	inner *fraudruntime.Scorer
}

func (s *mlScorer) score(_ context.Context, tx Transaction, profile *dynamo.UserProfile) (float64, bool) {
	features := buildMLFeatures(tx, s.inner.Spec().FeatureContract.FeatureOrder)
	result, err := s.inner.ScoreOne(fraudruntime.ScoreInput{
		TransactionID: tx.TransactionID,
		Features:      features,
	})
	if err != nil {
		log.Printf("ml engine error for tx=%s, falling back to rules: %v", tx.TransactionID, err)
		return rulesScore(tx, profile)
	}
	return result.CalibratedScore, result.PredictedLabel == 1
}

// rulesScorer applies the legacy rule-based engine when the ML model is unavailable.
type rulesScorer struct{}

func (r *rulesScorer) score(_ context.Context, tx Transaction, profile *dynamo.UserProfile) (float64, bool) {
	return rulesScore(tx, profile)
}

func rulesScore(tx Transaction, profile *dynamo.UserProfile) (float64, bool) {
	result := scoring.EvaluateDirect(tx.Amount, tx.Country, tx.DestinationAccount, profile)
	return float64(result.Score) / 100.0, result.Score >= 70
}

func main() {
	ctx := context.Background()

	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		log.Fatalf("failed to load AWS config: %v", err)
	}

	dynamoClient := dynamo.NewClient(dynamosvc.NewFromConfig(cfg))
	sqsClient := sqs.NewFromConfig(cfg)

	var s3Client *store.S3Client
	if os.Getenv("S3_AUDIT_BUCKET") != "" {
		var err error
		s3Client, err = store.NewS3Client(cfg)
		if err != nil {
			log.Printf("WARNING: failed to initialize S3 audit client: %v", err)
		} else {
			log.Printf("S3 audit enabled — bucket=%s", os.Getenv("S3_AUDIT_BUCKET"))
		}
	}

	engine := resolveScorer()

	queueURL := mustEnv("QUEUE_URL")
	resultsQueueURL := mustEnv("RESULTS_QUEUE_URL")
	fraudAlertQueueURL := mustEnv("FRAUD_ALERT_QUEUE_URL")
	processorConcurrency := envInt("PROCESSOR_CONCURRENCY", 32, 1, 512)
	processorPollers := envInt("PROCESSOR_POLLERS", 4, 1, 64)

	log.Printf("worker started — queue=%s results_queue=%s fraud_alert_queue=%s concurrency=%d pollers=%d",
		queueURL, resultsQueueURL, fraudAlertQueueURL, processorConcurrency, processorPollers)
	runLoop(ctx, sqsClient, dynamoClient, s3Client, engine, queueURL, resultsQueueURL, fraudAlertQueueURL, processorConcurrency, processorPollers)
}

// resolveScorer loads the ML engine when runtime_spec.json is available,
// otherwise falls back to rule-based scoring with a startup warning.
func resolveScorer() scorer {
	specPath, err := scoring.ResolveRuntimeSpecPath()
	if err != nil {
		log.Printf("WARNING: ML runtime spec not found (%v); using rule-based scoring", err)
		return &rulesScorer{}
	}

	s, err := fraudruntime.NewScorerFromSpecPath(specPath)
	if err != nil {
		log.Printf("WARNING: failed to load ML runtime spec at %s (%v); using rule-based scoring", specPath, err)
		return &rulesScorer{}
	}

	log.Printf("ML scoring engine loaded — spec=%s model_version=%s", specPath, s.Spec().ModelVersion)
	return &mlScorer{inner: s}
}

func runLoop(
	ctx context.Context,
	sqsClient queueClient,
	dynamoClient profileStore,
	s3Client *store.S3Client,
	engine scorer,
	queueURL, resultsQueueURL, fraudAlertQueueURL string,
	processorConcurrency, processorPollers int,
) {
	jobs := make(chan sqstypes.Message, processorConcurrency*10)
	userLocks := &userLockSet{}

	var workers sync.WaitGroup
	for workerID := range processorConcurrency {
		workers.Go(func() {
			for msg := range jobs {
				if err := processMessage(ctx, msg, sqsClient, dynamoClient, s3Client, engine, userLocks, queueURL, resultsQueueURL, fraudAlertQueueURL); err != nil {
					log.Printf("processing error worker=%d receipt=%s: %v", workerID, aws.ToString(msg.ReceiptHandle), err)
					// Do not delete — visibility timeout expires and the message retries.
					// After maxReceiveCount it lands in the DLQ.
				}
			}
		})
	}

	for pollerID := range processorPollers {
		go func(pollerID int) {
			for {
				out, err := sqsClient.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
					QueueUrl:            aws.String(queueURL),
					MaxNumberOfMessages: 10,
					WaitTimeSeconds:     20,
				})
				if err != nil {
					log.Printf("sqs receive error poller=%d: %v", pollerID, err)
					time.Sleep(5 * time.Second)
					continue
				}

				for _, msg := range out.Messages {
					jobs <- msg
				}
			}
		}(pollerID)
	}

	workers.Wait()
}

func processMessage(
	ctx context.Context,
	msg sqstypes.Message,
	sqsClient queueClient,
	dynamoClient profileStore,
	s3Client *store.S3Client,
	engine scorer,
	userLocks *userLockSet,
	queueURL, resultsQueueURL, fraudAlertQueueURL string,
) error {
	var tx Transaction
	if err := json.Unmarshal([]byte(aws.ToString(msg.Body)), &tx); err != nil {
		// Malformed JSON can never succeed — delete immediately to avoid DLQ noise.
		log.Printf("malformed message body, deleting: %v", err)
		deleteMessage(ctx, sqsClient, queueURL, msg.ReceiptHandle)
		return nil
	}
	if tx.TransactionID == "" || tx.UserID == "" {
		log.Printf("message missing required fields transaction_id/user_id, deleting")
		deleteMessage(ctx, sqsClient, queueURL, msg.ReceiptHandle)
		return nil
	}

	unlockUser := userLocks.lock(tx.UserID)
	defer unlockUser()

	profile, err := dynamoClient.GetProfile(ctx, tx.UserID)
	if err != nil {
		return fmt.Errorf("dynamo GetProfile user=%s: %w", tx.UserID, err)
	}

	fraudScore, isFraud := engine.score(ctx, tx, profile)

	// Update the user profile with the new transaction regardless of the score.
	if err := dynamoClient.UpdateProfile(
		ctx, profile, tx.Amount, tx.Country, tx.Channel, tx.DestinationAccount, tx.Timestamp,
	); err != nil {
		return fmt.Errorf("dynamo UpdateProfile user=%s: %w", tx.UserID, err)
	}

	result := ScoringResult{
		TransactionID: tx.TransactionID,
		UserID:        tx.UserID,
		Amount:        tx.Amount,
		Currency:      tx.Currency,
		Country:       tx.Country,
		Channel:       tx.Channel,
		FraudScore:    fraudScore,
		IsFraud:       isFraud,
		ProcessedAt:   time.Now().UTC().Format(time.RFC3339),
	}

	if s3Client != nil {
		audit := AuditEvent{
			Transaction:   tx,
			ScoringResult: result,
			ProcessedAt:   result.ProcessedAt,
		}
		if err := s3Client.PutRawEvent(ctx, tx.TransactionID, audit); err != nil {
			log.Printf("s3 audit error tx=%s: %v", tx.TransactionID, err)
		}
	}

	if err := publishScoringResult(ctx, sqsClient, resultsQueueURL, fraudAlertQueueURL, result); err != nil {
		return err
	}

	deleteMessage(ctx, sqsClient, queueURL, msg.ReceiptHandle)

	log.Printf("processed tx=%s user=%s fraud_score=%.4f is_fraud=%v",
		tx.TransactionID, tx.UserID, fraudScore, isFraud)

	return nil
}

func publishScoringResult(
	ctx context.Context,
	sqsClient queueClient,
	resultsQueueURL, fraudAlertQueueURL string,
	result ScoringResult,
) error {
	payload, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("marshal scoring result tx=%s: %w", result.TransactionID, err)
	}

	if _, err := sqsClient.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:    aws.String(resultsQueueURL),
		MessageBody: aws.String(string(payload)),
	}); err != nil {
		return fmt.Errorf("sqs send result tx=%s queue=%s: %w", result.TransactionID, resultsQueueURL, err)
	}

	if result.IsFraud {
		if _, err := sqsClient.SendMessage(ctx, &sqs.SendMessageInput{
			QueueUrl:    aws.String(fraudAlertQueueURL),
			MessageBody: aws.String(string(payload)),
		}); err != nil {
			return fmt.Errorf("sqs send fraud alert tx=%s queue=%s: %w", result.TransactionID, fraudAlertQueueURL, err)
		}
	}

	return nil
}

// buildMLFeatures constructs the feature map expected by the Go runtime.
// All features in the contract are initialised to NaN; the model's
// MissingGoToLeft strategy handles absent fields during tree traversal.
// Derived features are computed when their source fields are present.
func buildMLFeatures(tx Transaction, featureOrder []string) map[string]float64 {
	features := make(map[string]float64, len(featureOrder))
	for _, name := range featureOrder {
		features[name] = math.NaN()
	}

	features["amount"] = tx.Amount
	features["amount_log1p"] = signedLog1p(tx.Amount)

	if tx.OldBalanceOrg != nil {
		features["oldbalance_org"] = *tx.OldBalanceOrg
		features["oldbalance_org_log1p"] = signedLog1p(*tx.OldBalanceOrg)
		if *tx.OldBalanceOrg != 0 {
			r := tx.Amount / *tx.OldBalanceOrg
			features["amount_to_oldbalance_ratio"] = r
			features["amount_to_oldbalance_ratio_bounded"] = clamp(r, -10, 10)
		}
	}

	if tx.NewBalanceOrig != nil {
		features["newbalance_orig"] = *tx.NewBalanceOrig
		features["newbalance_orig_log1p"] = signedLog1p(*tx.NewBalanceOrig)
		if *tx.NewBalanceOrig != 0 {
			r := tx.Amount / *tx.NewBalanceOrig
			features["amount_to_newbalance_ratio"] = r
			features["amount_to_newbalance_ratio_bounded"] = clamp(r, -10, 10)
		}
	}

	if tx.OldBalanceOrg != nil && tx.NewBalanceOrig != nil {
		delta := *tx.NewBalanceOrig - *tx.OldBalanceOrg
		features["balance_delta_org"] = delta
		features["balance_delta_org_log1p"] = signedLog1p(delta)
	}

	if tx.OldBalanceDest != nil {
		features["oldbalance_dest"] = *tx.OldBalanceDest
		features["oldbalance_dest_log1p"] = signedLog1p(*tx.OldBalanceDest)
		if *tx.OldBalanceDest != 0 {
			r := tx.Amount / *tx.OldBalanceDest
			features["amount_to_dest_oldbalance_ratio"] = r
			features["amount_to_dest_oldbalance_ratio_bounded"] = clamp(r, -10, 10)
		}
	}

	if tx.NewBalanceDest != nil {
		features["newbalance_dest"] = *tx.NewBalanceDest
		features["newbalance_dest_log1p"] = signedLog1p(*tx.NewBalanceDest)
		if *tx.NewBalanceDest != 0 {
			r := tx.Amount / *tx.NewBalanceDest
			features["amount_to_dest_newbalance_ratio"] = r
			features["amount_to_dest_newbalance_ratio_bounded"] = clamp(r, -10, 10)
		}
	}

	if tx.OldBalanceDest != nil && tx.NewBalanceDest != nil {
		delta := *tx.NewBalanceDest - *tx.OldBalanceDest
		features["balance_delta_dest"] = delta
		features["balance_delta_dest_log1p"] = signedLog1p(delta)
	}

	for k, v := range tx.Features {
		if _, inContract := features[k]; inContract {
			features[k] = v
		}
	}

	return features
}

func deleteMessage(ctx context.Context, sqsClient queueClient, queueURL string, receiptHandle *string) {
	if _, err := sqsClient.DeleteMessage(ctx, &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(queueURL),
		ReceiptHandle: receiptHandle,
	}); err != nil {
		log.Printf("sqs delete error: %v", err)
	}
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("required environment variable %s is not set", key)
	}
	return v
}

func envInt(key string, defaultValue, minValue, maxValue int) int {
	raw := os.Getenv(key)
	if raw == "" {
		return defaultValue
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		log.Fatalf("environment variable %s must be an integer, got %q", key, raw)
	}
	if value < minValue {
		return minValue
	}
	if value > maxValue {
		return maxValue
	}
	return value
}

func signedLog1p(x float64) float64 {
	if x >= 0 {
		return math.Log1p(x)
	}
	return -math.Log1p(-x)
}

func clamp(x, min, max float64) float64 {
	if x < min {
		return min
	}
	if x > max {
		return max
	}
	return x
}
