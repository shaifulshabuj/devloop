package storage

// ModelPricing holds per-token pricing for a model (in USD per 1M tokens).
type ModelPricing struct {
	InputPer1M  float64
	OutputPer1M float64
}

// KnownPricing maps model names to pricing (approximate 2024 rates).
var KnownPricing = map[string]ModelPricing{
	"claude-opus-4-5":   {InputPer1M: 15.0, OutputPer1M: 75.0},
	"claude-sonnet-4-5": {InputPer1M: 3.0, OutputPer1M: 15.0},
	"claude-haiku-4-5":  {InputPer1M: 0.25, OutputPer1M: 1.25},
}

// defaultPricing is used when the model is not found in KnownPricing.
var defaultPricing = KnownPricing["claude-sonnet-4-5"]

// TaskCost holds the estimated cost for a task.
type TaskCost struct {
	TaskID       string
	Model        string
	InputTokens  int
	OutputTokens int
	EstimatedUSD float64
}

// ComputeAllCosts loads up to limit tasks from the store and estimates cost for each.
// The model string is applied to every task; pass "" to fall back to the default pricing.
func ComputeAllCosts(store *Store, model string, limit int) ([]TaskCost, error) {
	tasks, err := store.ListTasks(limit)
	if err != nil {
		return nil, err
	}

	if model == "" {
		model = "claude-sonnet-4-5"
	}

	costs := make([]TaskCost, 0, len(tasks))
	for _, t := range tasks {
		entries, err := store.GetContext(t.ID)
		if err != nil {
			continue
		}
		tc := EstimateCost(t.ID, model, entries)
		costs = append(costs, tc)
	}
	return costs, nil
}
// Heuristic: 1 token ≈ 4 characters.
// user/system role entries count as input tokens; assistant role counts as output tokens.
// Looks up pricing in KnownPricing; defaults to Sonnet pricing if the model is unknown.
func EstimateCost(taskID, model string, entries []*ContextEntry) TaskCost {
	var inputTokens, outputTokens int

	for _, e := range entries {
		chars := len(e.Content)
		tokens := chars / 4
		if chars%4 != 0 {
			tokens++
		}

		switch e.Role {
		case "assistant":
			outputTokens += tokens
		default: // "user", "system", or any other role → input
			inputTokens += tokens
		}
	}

	pricing, ok := KnownPricing[model]
	if !ok {
		pricing = defaultPricing
	}

	costUSD := (float64(inputTokens)/1_000_000)*pricing.InputPer1M +
		(float64(outputTokens)/1_000_000)*pricing.OutputPer1M

	return TaskCost{
		TaskID:       taskID,
		Model:        model,
		InputTokens:  inputTokens,
		OutputTokens: outputTokens,
		EstimatedUSD: costUSD,
	}
}
