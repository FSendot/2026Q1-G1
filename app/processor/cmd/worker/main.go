package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"time"

	"github.com/FSendot/fraud-detector/processor/internal/dynamo"
	"github.com/FSendot/fraud-detector/processor/internal/scoring"
	"github.com/FSendot/fraud-detector/processor/internal/store"
	fraudruntime "github.com/FSendot/fraud-detector/net/serving/go/pkg/fraudruntime"
	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	dynamosvc "github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/sns"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	sqstypes "github.com/aws/aws-sdk-go-v2/service/sqs/types"
)

// Transaction is the JSON payload expected from the SQS queue.
// Balance fields are optional: when absent the ML engine applies its
// MissingGoToLeft strategy for those tree splits.
type Transaction struct {
	TransactionID      string   `json:"transaction_id"`
	UserID             string   `json:"user_id"`
	Amount             float64  `json:"amount"`
	Currency           string   `json:"currency"`
	Timestamp          string   `json:"timestamp"`
	Channel            string   `json:"channel"`
	DestinationAccount string   `json:"destination_account"`
	Country            string   `json:"country"`
	OldBalanceOrg      *float64 `json:"oldbalance_org,omitempty"`
	NewBalanceOrig     *float64 `json:"newbalance_orig,omitempty"`
	OldBalanceDest     *float64 `json:"oldbalance_dest,omitempty"`
	NewBalanceDest     *float64 `json:"newbalance_dest,omitempty"`
}

// ScoringResult is published to SNS after scoring.
type ScoringResult struct {
	TransactionID string  `json:"transaction_id"`
	UserID        string  `json:"user_id"`
	FraudScore    float64 `json:"fraud_score"`
	IsFraud       bool    `json:"is_fraud"`
}

// AuditEvent is written to S3 for full traceability.
type AuditEvent struct {
	Transaction   Transaction   `json:"transaction"`
	ScoringResult ScoringResult `json:"scoring_result"`
	ProcessedAt   string        `json:"processed_at"`
}

// scorer abstracts ML engine and rule-based fallback behind a single interface.
type scorer interface {
	score(ctx context.Context, tx Transaction, profile *dynamo.UserProfile) (fraudScore float64, isFraud bool)
}

// mlScorer uses the trained Go runtime loaded from runtime_spec.json.
type mlScorer struct {
	inner *fraudruntime.Scorer
}

func (s *mlScorer) score(_ context.Context, tx Transaction, _ *dynamo.UserProfile) (float64, bool) {
	features := buildMLFeatures(tx, s.inner.Spec().FeatureContract.FeatureOrder)
	result, err := s.inner.ScoreOne(fraudruntime.ScoreInput{
		TransactionID: tx.TransactionID,
		Features:      features,
	})
	if err != nil {
		log.Printf("ml engine error for tx=%s, falling back to rules: %v", tx.TransactionID, err)
		return rulesScore(tx, &dynamo.UserProfile{})
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
	snsClient := sns.NewFromConfig(cfg)

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
	topicARN := mustEnv("SNS_TOPIC_ARN")

	log.Printf("worker started — queue=%s topic=%s", queueURL, topicARN)
	runLoop(ctx, sqsClient, snsClient, dynamoClient, s3Client, engine, queueURL, topicARN)
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
	sqsClient *sqs.Client,
	snsClient *sns.Client,
	dynamoClient *dynamo.Client,
	s3Client *store.S3Client,
	engine scorer,
	queueURL, topicARN string,
) {
	for {
		out, err := sqsClient.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:            aws.String(queueURL),
			MaxNumberOfMessages: 10,
			WaitTimeSeconds:     20,
		})
		if err != nil {
			log.Printf("sqs receive error: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}

		for _, msg := range out.Messages {
			if err := processMessage(ctx, msg, sqsClient, snsClient, dynamoClient, s3Client, engine, queueURL, topicARN); err != nil {
				log.Printf("processing error receipt=%s: %v", aws.ToString(msg.ReceiptHandle), err)
				// Do not delete — visibility timeout expires and the message retries.
				// After maxReceiveCount it lands in the DLQ.
			}
		}
	}
}

func processMessage(
	ctx context.Context,
	msg sqstypes.Message,
	sqsClient *sqs.Client,
	snsClient *sns.Client,
	dynamoClient *dynamo.Client,
	s3Client *store.S3Client,
	engine scorer,
	queueURL, topicARN string,
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

	profile, err := dynamoClient.GetProfile(ctx, tx.UserID)
	if err != nil {
		return fmt.Errorf("dynamo GetProfile user=%s: %w", tx.UserID, err)
	}

	fraudScore, isFraud := engine.score(ctx, tx, profile)

	// Update the user profile with the new transaction regardless of the score.
	if err := dynamoClient.UpdateProfile(
		ctx, profile, tx.Amount, tx.Country, tx.Channel, tx.DestinationAccount, tx.Timestamp,
	); err != nil {
		log.Printf("dynamo UpdateProfile user=%s: %v", tx.UserID, err)
	}

	result := ScoringResult{
		TransactionID: tx.TransactionID,
		UserID:        tx.UserID,
		FraudScore:    fraudScore,
		IsFraud:       isFraud,
	}

	if s3Client != nil {
		audit := AuditEvent{
			Transaction:   tx,
			ScoringResult: result,
			ProcessedAt:   time.Now().UTC().Format(time.RFC3339),
		}
		if err := s3Client.PutRawEvent(ctx, tx.TransactionID, audit); err != nil {
			log.Printf("s3 audit error tx=%s: %v", tx.TransactionID, err)
		}
	}

	payload, _ := json.Marshal(result)

	if _, err := snsClient.Publish(ctx, &sns.PublishInput{
		TopicArn: aws.String(topicARN),
		Message:  aws.String(string(payload)),
	}); err != nil {
		return fmt.Errorf("sns publish tx=%s: %w", tx.TransactionID, err)
	}

	deleteMessage(ctx, sqsClient, queueURL, msg.ReceiptHandle)

	log.Printf("processed tx=%s user=%s fraud_score=%.4f is_fraud=%v",
		tx.TransactionID, tx.UserID, fraudScore, isFraud)

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

	return features
}

func deleteMessage(ctx context.Context, sqsClient *sqs.Client, queueURL string, receiptHandle *string) {
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
