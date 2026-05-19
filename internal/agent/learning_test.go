package agent

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestExtract_Keywords verifies that a line containing "lesson: <content>"
// yields a lesson with the correct content.
func TestExtract_Keywords(t *testing.T) {
	ll := NewLearningLoop("ignored.md")
	results := []LessonInput{
		{Output: "some output\nlesson: use smaller commits\nmore output"},
	}
	lessons := ll.Extract("task-id", "My Task", results)
	if len(lessons) != 1 {
		t.Fatalf("expected 1 lesson, got %d", len(lessons))
	}
	if lessons[0].Content != "use smaller commits" {
		t.Errorf("unexpected content: %q", lessons[0].Content)
	}
	if lessons[0].TaskID != "task-id" {
		t.Errorf("unexpected TaskID: %q", lessons[0].TaskID)
	}
	if lessons[0].TaskTitle != "My Task" {
		t.Errorf("unexpected TaskTitle: %q", lessons[0].TaskTitle)
	}
}

// TestExtract_Keywords_CaseInsensitive verifies that keyword matching is
// case-insensitive (e.g. "TIP:", "IMPORTANT:").
func TestExtract_Keywords_CaseInsensitive(t *testing.T) {
	ll := NewLearningLoop("ignored.md")
	cases := []struct {
		output  string
		wantLen int
	}{
		{"TIP: always test first", 1},
		{"IMPORTANT: never skip review", 1},
		{"Note: document your changes", 1},
		{"REMEMBER: run lint before commit", 1},
	}
	for _, tc := range cases {
		lessons := ll.Extract("id", "Title", []LessonInput{{Output: tc.output}})
		if len(lessons) != tc.wantLen {
			t.Errorf("output %q: expected %d lessons, got %d", tc.output, tc.wantLen, len(lessons))
		}
	}
}

// TestExtract_FailedStep verifies that a failed step with no keywords produces
// a single fallback lesson containing the task title and error text.
func TestExtract_FailedStep(t *testing.T) {
	ll := NewLearningLoop("ignored.md")
	results := []LessonInput{
		{Output: "no keywords here", Err: errors.New("exit code 1")},
	}
	lessons := ll.Extract("task-id", "My Task", results)
	if len(lessons) != 1 {
		t.Fatalf("expected 1 fallback lesson, got %d", len(lessons))
	}
	if !strings.Contains(lessons[0].Content, "My Task") {
		t.Errorf("expected task title in fallback lesson, got: %q", lessons[0].Content)
	}
	if !strings.Contains(lessons[0].Content, "exit code 1") {
		t.Errorf("expected error text in fallback lesson, got: %q", lessons[0].Content)
	}
}

// TestExtract_NoKeywords_NoError verifies that a clean step with no keywords
// and no error yields no lessons.
func TestExtract_NoKeywords_NoError(t *testing.T) {
	ll := NewLearningLoop("ignored.md")
	results := []LessonInput{
		{Output: "all good, nothing special"},
	}
	lessons := ll.Extract("task-id", "My Task", results)
	if len(lessons) != 0 {
		t.Fatalf("expected 0 lessons, got %d: %v", len(lessons), lessons)
	}
}

// TestExtract_KeywordsWithError verifies that when keywords are found and a step
// also failed, the keyword lessons are returned (not the fallback).
func TestExtract_KeywordsWithError(t *testing.T) {
	ll := NewLearningLoop("ignored.md")
	results := []LessonInput{
		{Output: "tip: check logs carefully", Err: errors.New("timeout")},
	}
	lessons := ll.Extract("id", "Deploy", results)
	if len(lessons) != 1 {
		t.Fatalf("expected 1 keyword lesson, got %d", len(lessons))
	}
	if !strings.Contains(lessons[0].Content, "check logs carefully") {
		t.Errorf("unexpected content: %q", lessons[0].Content)
	}
}

// TestPersist verifies that Persist writes valid markdown to the lessons file
// and creates the parent directories as needed.
func TestPersist(t *testing.T) {
	dir := t.TempDir()
	lessonsPath := filepath.Join(dir, ".devloop", "lessons.md")
	ll := NewLearningLoop(lessonsPath)

	lessons := []Lesson{
		{TaskID: "abcdef123456", TaskTitle: "Deploy Service", Content: "use smaller commits"},
		{TaskID: "abcdef123456", TaskTitle: "Deploy Service", Content: "write tests first"},
	}

	if err := ll.Persist("Deploy Service", "abcdef123456", lessons); err != nil {
		t.Fatalf("Persist returned error: %v", err)
	}

	data, err := os.ReadFile(lessonsPath)
	if err != nil {
		t.Fatalf("reading lessons file: %v", err)
	}
	content := string(data)

	for _, want := range []string{
		"Deploy Service",
		"abcdef12", // first 8 chars of task ID
		"use smaller commits",
		"write tests first",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("expected %q in lessons file:\n%s", want, content)
		}
	}
}

// TestPersist_Empty verifies that Persist does nothing when lessons is empty.
func TestPersist_Empty(t *testing.T) {
	dir := t.TempDir()
	lessonsPath := filepath.Join(dir, "lessons.md")
	ll := NewLearningLoop(lessonsPath)

	if err := ll.Persist("Title", "id", nil); err != nil {
		t.Fatalf("Persist returned error for empty lessons: %v", err)
	}
	if _, err := os.Stat(lessonsPath); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("expected lessons file not to be created for empty input")
	}
}

// TestExtractAndPersist is an integration test for the convenience method.
func TestExtractAndPersist(t *testing.T) {
	dir := t.TempDir()
	lessonsPath := filepath.Join(dir, "lessons.md")
	ll := NewLearningLoop(lessonsPath)

	results := []LessonInput{
		{Output: "note: always check permissions"},
	}
	if err := ll.ExtractAndPersist("abc123", "Setup Task", results); err != nil {
		t.Fatalf("ExtractAndPersist returned error: %v", err)
	}

	data, err := os.ReadFile(lessonsPath)
	if err != nil {
		t.Fatalf("reading lessons file: %v", err)
	}
	if !strings.Contains(string(data), "always check permissions") {
		t.Errorf("expected lesson in file:\n%s", string(data))
	}
}
