package agent

import (
	"strings"
)

// QuestionDetector scans agent output lines for question patterns.
type QuestionDetector struct{}

// NewQuestionDetector returns a new QuestionDetector.
func NewQuestionDetector() *QuestionDetector {
	return &QuestionDetector{}
}

// IsQuestion returns true if the line looks like the agent is asking a question.
// Detection heuristics (check in order):
//  1. Line ends with "?" (after trimming whitespace)
//  2. Line contains "[y/n]", "[yes/no]", "(y/n)", "(yes/no)" (case-insensitive)
//  3. Line starts with "Please", "Would you", "Do you", "Can you", "Should I",
//     "Which", "What", "How", "When", "Where", "Is it", "Are you" (case-insensitive)
//  4. Line contains "your choice:", "enter your", "select one" (case-insensitive)
//
// Returns false for empty lines.
func (d *QuestionDetector) IsQuestion(line string) bool {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" {
		return false
	}

	// Heuristic 1: ends with "?"
	if strings.HasSuffix(trimmed, "?") {
		return true
	}

	lower := strings.ToLower(trimmed)

	// Heuristic 2: contains choice markers
	choiceMarkers := []string{"[y/n]", "[yes/no]", "(y/n)", "(yes/no)"}
	for _, marker := range choiceMarkers {
		if strings.Contains(lower, marker) {
			return true
		}
	}

	// Heuristic 3: starts with question prefixes
	questionPrefixes := []string{
		"please ",
		"would you",
		"do you",
		"can you",
		"should i",
		"which ",
		"what ",
		"how ",
		"when ",
		"where ",
		"is it",
		"are you",
	}
	for _, prefix := range questionPrefixes {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}

	// Heuristic 4: contains input prompt patterns
	inputPatterns := []string{"your choice:", "enter your", "select one"}
	for _, pattern := range inputPatterns {
		if strings.Contains(lower, pattern) {
			return true
		}
	}

	return false
}

// ExtractQuestion returns the question text from a line (trimmed).
func (d *QuestionDetector) ExtractQuestion(line string) string {
	return strings.TrimSpace(line)
}
