package storage

import (
	"testing"
)

func TestEstimateCost_KnownModel(t *testing.T) {
	entries := []*ContextEntry{
		{Role: "user", Content: "Hello, please help me write a function."},
		{Role: "assistant", Content: "Sure! Here is a function that does what you asked."},
		{Role: "system", Content: "You are a helpful assistant."},
	}

	cost := EstimateCost("task-1", "claude-sonnet-4-5", entries)

	if cost.TaskID != "task-1" {
		t.Errorf("expected TaskID task-1, got %q", cost.TaskID)
	}
	if cost.Model != "claude-sonnet-4-5" {
		t.Errorf("expected Model claude-sonnet-4-5, got %q", cost.Model)
	}
	if cost.InputTokens <= 0 {
		t.Errorf("expected positive InputTokens, got %d", cost.InputTokens)
	}
	if cost.OutputTokens <= 0 {
		t.Errorf("expected positive OutputTokens, got %d", cost.OutputTokens)
	}
	if cost.EstimatedUSD <= 0 {
		t.Errorf("expected positive EstimatedUSD for known model, got %f", cost.EstimatedUSD)
	}
}

func TestEstimateCost_UnknownModel(t *testing.T) {
	entries := []*ContextEntry{
		{Role: "user", Content: "What is the capital of France?"},
		{Role: "assistant", Content: "The capital of France is Paris."},
	}

	cost := EstimateCost("task-2", "gpt-unknown-model", entries)

	if cost.Model != "gpt-unknown-model" {
		t.Errorf("expected Model gpt-unknown-model, got %q", cost.Model)
	}
	if cost.InputTokens <= 0 {
		t.Errorf("expected positive InputTokens, got %d", cost.InputTokens)
	}
	if cost.OutputTokens <= 0 {
		t.Errorf("expected positive OutputTokens, got %d", cost.OutputTokens)
	}

	// Verify it used Sonnet default pricing by computing expected cost manually.
	pricing := defaultPricing
	expectedUSD := (float64(cost.InputTokens)/1_000_000)*pricing.InputPer1M +
		(float64(cost.OutputTokens)/1_000_000)*pricing.OutputPer1M
	if cost.EstimatedUSD != expectedUSD {
		t.Errorf("expected EstimatedUSD %f (Sonnet default), got %f", expectedUSD, cost.EstimatedUSD)
	}
}

func TestEstimateCost_Empty(t *testing.T) {
	cost := EstimateCost("task-3", "claude-opus-4-5", nil)

	if cost.InputTokens != 0 {
		t.Errorf("expected InputTokens 0 for empty entries, got %d", cost.InputTokens)
	}
	if cost.OutputTokens != 0 {
		t.Errorf("expected OutputTokens 0 for empty entries, got %d", cost.OutputTokens)
	}
	if cost.EstimatedUSD != 0 {
		t.Errorf("expected EstimatedUSD 0 for empty entries, got %f", cost.EstimatedUSD)
	}
}
