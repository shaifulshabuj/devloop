package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Lesson represents a single extracted learning from a task.
type Lesson struct {
	TaskID    string
	TaskTitle string
	Content   string    // the lesson text
	CreatedAt time.Time
}

// LessonInput carries the data Extract needs from a step result.
type LessonInput struct {
	Output string
	Err    error
}

// LearningLoop extracts and persists lessons from task results.
type LearningLoop struct {
	lessonsPath string // e.g. ".devloop/lessons.md"
}

// NewLearningLoop creates a LearningLoop that writes lessons to lessonsPath.
func NewLearningLoop(lessonsPath string) *LearningLoop {
	return &LearningLoop{lessonsPath: lessonsPath}
}

// lessonTriggers are the keyword prefixes that mark a line as a lesson
// (case-insensitive, colon included).
var lessonTriggers = []string{"lesson:", "note:", "important:", "remember:", "tip:"}

// Extract returns lessons from a set of step results.
// It scans each result's Output for lines containing any trigger keyword
// (case-insensitive) and treats the text after the keyword as the lesson content.
// If no keyword lines are found and at least one result has a non-nil Err,
// a single fallback lesson is returned: "Task '<taskTitle>' failed: <err>".
func (l *LearningLoop) Extract(taskID, taskTitle string, results []LessonInput) []Lesson {
	var lessons []Lesson
	var firstErr error

	for _, r := range results {
		if r.Err != nil && firstErr == nil {
			firstErr = r.Err
		}

		for _, line := range strings.Split(r.Output, "\n") {
			lower := strings.ToLower(line)
			for _, kw := range lessonTriggers {
				idx := strings.Index(lower, kw)
				if idx == -1 {
					continue
				}
				content := strings.TrimSpace(line[idx+len(kw):])
				if content == "" {
					continue
				}
				lessons = append(lessons, Lesson{
					TaskID:    taskID,
					TaskTitle: taskTitle,
					Content:   content,
					CreatedAt: time.Now(),
				})
				break // one keyword match per line is sufficient
			}
		}
	}

	if len(lessons) == 0 && firstErr != nil {
		lessons = append(lessons, Lesson{
			TaskID:    taskID,
			TaskTitle: taskTitle,
			Content:   fmt.Sprintf("Task '%s' failed: %s", taskTitle, firstErr.Error()),
			CreatedAt: time.Now(),
		})
	}

	return lessons
}

// Persist appends lessons to the lessonsPath file in markdown format:
//
//	## <taskTitle> (<taskID[:8]>) — <date>
//	- <lesson1>
//	- <lesson2>
//
// Creates the file and any parent directories if they don't exist.
// Does nothing if lessons is empty.
func (l *LearningLoop) Persist(taskTitle, taskID string, lessons []Lesson) error {
	if len(lessons) == 0 {
		return nil
	}

	if err := os.MkdirAll(filepath.Dir(l.lessonsPath), 0o755); err != nil {
		return fmt.Errorf("creating lessons directory: %w", err)
	}

	f, err := os.OpenFile(l.lessonsPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("opening lessons file: %w", err)
	}
	defer f.Close() //nolint:errcheck

	idSuffix := taskID
	if len(idSuffix) > 8 {
		idSuffix = idSuffix[:8]
	}

	header := fmt.Sprintf("\n## %s (%s) — %s\n", taskTitle, idSuffix, time.Now().Format("2006-01-02"))
	if _, err := fmt.Fprint(f, header); err != nil {
		return fmt.Errorf("writing lesson header: %w", err)
	}

	for _, lesson := range lessons {
		if _, err := fmt.Fprintf(f, "- %s\n", lesson.Content); err != nil {
			return fmt.Errorf("writing lesson: %w", err)
		}
	}

	return nil
}

// ExtractAndPersist is a convenience method combining Extract and Persist.
func (l *LearningLoop) ExtractAndPersist(taskID, taskTitle string, results []LessonInput) error {
	lessons := l.Extract(taskID, taskTitle, results)
	return l.Persist(taskTitle, taskID, lessons)
}
