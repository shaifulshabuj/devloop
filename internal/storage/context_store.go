package storage

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Message represents a single conversation message stored in a ContextStore.
type Message struct {
	ID        string    `json:"id"`
	TaskID    string    `json:"task_id"`
	Role      string    `json:"role"`    // "user", "assistant", "system"
	Content   string    `json:"content"`
	CreatedAt time.Time `json:"created_at"`
}

// ContextStore holds conversation messages in memory and optionally persists
// them to a JSONL file for crash recovery.
type ContextStore struct {
	mu       sync.RWMutex
	messages []Message
	filePath string // empty = memory-only
}

// NewContextStore creates a ContextStore. If filePath is non-empty, existing
// messages are loaded from the JSONL file (one JSON object per line).
// A missing file is not an error.
func NewContextStore(filePath string) (*ContextStore, error) {
	cs := &ContextStore{filePath: filePath}

	if filePath == "" {
		return cs, nil
	}

	f, err := os.Open(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			return cs, nil
		}
		return nil, fmt.Errorf("opening context file %q: %w", filePath, err)
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var msg Message
		if err := json.Unmarshal(line, &msg); err != nil {
			return nil, fmt.Errorf("parsing context file %q: %w", filePath, err)
		}
		cs.messages = append(cs.messages, msg)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("reading context file %q: %w", filePath, err)
	}

	return cs, nil
}

// Add appends a message to the in-memory store and, if filePath is set,
// appends it as a JSON line to the file. If msg.ID is empty a new UUID is
// assigned before storing.
func (c *ContextStore) Add(msg Message) error {
	if msg.ID == "" {
		msg.ID = uuid.New().String()
	}
	if msg.CreatedAt.IsZero() {
		msg.CreatedAt = time.Now()
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	c.messages = append(c.messages, msg)

	if c.filePath == "" {
		return nil
	}

	line, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshalling message: %w", err)
	}

	f, err := os.OpenFile(c.filePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("opening context file %q for append: %w", c.filePath, err)
	}
	defer func() { _ = f.Close() }()

	line = append(line, '\n')
	if _, err = f.Write(line); err != nil {
		return fmt.Errorf("writing to context file %q: %w", c.filePath, err)
	}

	return nil
}

// GetByTaskID returns all messages for the given taskID (safe for concurrent use).
func (c *ContextStore) GetByTaskID(taskID string) []Message {
	c.mu.RLock()
	defer c.mu.RUnlock()

	var result []Message
	for _, m := range c.messages {
		if m.TaskID == taskID {
			result = append(result, m)
		}
	}
	return result
}

// All returns a snapshot of all messages.
func (c *ContextStore) All() []Message {
	c.mu.RLock()
	defer c.mu.RUnlock()

	snapshot := make([]Message, len(c.messages))
	copy(snapshot, c.messages)
	return snapshot
}

// Clear removes all messages for the given taskID from memory.
// The backing file is not modified.
func (c *ContextStore) Clear(taskID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	filtered := c.messages[:0]
	for _, m := range c.messages {
		if m.TaskID != taskID {
			filtered = append(filtered, m)
		}
	}
	c.messages = filtered
}
