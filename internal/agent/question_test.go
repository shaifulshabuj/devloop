package agent

import (
	"testing"
)

func TestIsQuestion_TruePositives(t *testing.T) {
	d := NewQuestionDetector()

	cases := []struct {
		name string
		line string
	}{
		{"ends with question mark", "Are you sure?"},
		{"starts with Would you", "Would you like to proceed?"},
		{"contains y/n brackets", "Continue? [y/n]"},
		{"starts with Please", "Please confirm the action"},
		{"starts with Do you", "Do you want to overwrite?"},
		{"starts with Can you", "Can you provide more details?"},
		{"starts with Should I", "Should I continue with the operation?"},
		{"starts with Which", "Which option do you prefer?"},
		{"starts with What", "What is the target directory?"},
		{"starts with How", "How many retries do you want?"},
		{"starts with When", "When should the task run?"},
		{"starts with Where", "Where should the output be saved?"},
		{"starts with Is it", "Is it okay to delete the file?"},
		{"starts with Are you", "Are you sure you want to continue?"},
		{"contains yes/no brackets", "Do you agree? [yes/no]"},
		{"contains (y/n)", "Proceed (y/n):"},
		{"contains (yes/no)", "Accept changes (yes/no)?"},
		{"contains your choice:", "Enter your choice: 1, 2, or 3"},
		{"contains enter your", "Enter your name:"},
		{"contains select one", "Select one of the options below"},
		{"case-insensitive prefix", "PLEASE confirm"},
		{"case-insensitive choice marker", "Continue? [Y/N]"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if !d.IsQuestion(tc.line) {
				t.Errorf("IsQuestion(%q) = false, want true", tc.line)
			}
		})
	}
}

func TestIsQuestion_FalseNegatives(t *testing.T) {
	d := NewQuestionDetector()

	cases := []struct {
		name string
		line string
	}{
		{"processing status", "Processing..."},
		{"done message", "Done."},
		{"empty string", ""},
		{"whitespace only", "   "},
		{"plain log line", "Running build pipeline"},
		{"error message", "Error: file not found"},
		{"info message", "Starting agent session"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if d.IsQuestion(tc.line) {
				t.Errorf("IsQuestion(%q) = true, want false", tc.line)
			}
		})
	}
}
