package scoring

import (
	"testing"

	"github.com/FSendot/fraud-detector/processor/internal/dynamo"
)

func baseProfile() *dynamo.UserProfile {
	return &dynamo.UserProfile{
		UserID:            "u_123",
		AvgAmount:         4500,
		StdDevAmount:      1200,
		TxCount:           142,
		TxLastHour:        2,
		TxLast10Min:       0,
		TypicalCountries:  []string{"AR", "UY"},
		TypicalChannels:   []string{"web", "mobile"},
		KnownDestinations: []string{"acc_456", "acc_789"},
		LastCountry:       "AR",
		LastTimestamp:     "2026-04-03T10:22:00Z",
	}
}

func TestAllowNormalTransaction(t *testing.T) {
	r := EvaluateDirect(5000, "AR", "acc_456", baseProfile())

	if r.Decision != "allowed" {
		t.Errorf("expected allowed, got %s (score=%d)", r.Decision, r.Score)
	}
	if r.FlagAmount || r.FlagCountry || r.FlagDestination || r.FlagVelocity {
		t.Errorf("no flags expected, got amount=%v country=%v dest=%v velocity=%v",
			r.FlagAmount, r.FlagCountry, r.FlagDestination, r.FlagVelocity)
	}
}

func TestBlockHighRisk(t *testing.T) {
	r := EvaluateDirect(15000, "BR", "acc_999", baseProfile())

	if !r.FlagAmount {
		t.Error("expected flag_amount=true")
	}
	if !r.FlagCountry {
		t.Error("expected flag_country=true")
	}
	if !r.FlagDestination {
		t.Error("expected flag_destination=true")
	}
	if r.Decision != "challenged" {
		t.Errorf("expected challenged, got %s (score=%d)", r.Decision, r.Score)
	}
}

func TestBlockWithVelocity(t *testing.T) {
	profile := baseProfile()
	profile.TxLast10Min = 3

	r := EvaluateDirect(15000, "BR", "acc_999", profile)

	if r.Score != 100 {
		t.Errorf("expected score=100, got %d", r.Score)
	}
	if r.Decision != "blocked" {
		t.Errorf("expected blocked, got %s", r.Decision)
	}
}

func TestChallengeMiddleScore(t *testing.T) {
	r := EvaluateDirect(15000, "AR", "acc_999", baseProfile())

	if r.Score != 40 {
		t.Errorf("expected score=40, got %d", r.Score)
	}
	if r.Decision != "challenged" {
		t.Errorf("expected challenged, got %s", r.Decision)
	}
}

func TestNewUserNoFlags(t *testing.T) {
	profile := dynamo.NewDefaultProfile("u_new")
	r := EvaluateDirect(99999, "JP", "acc_unknown", profile)

	if r.Decision != "allowed" {
		t.Errorf("new user should be allowed, got %s (score=%d)", r.Decision, r.Score)
	}
}
