package stream

import (
	"bufio"
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/fsnotify/fsnotify"
)

// Tailer tails a single NDJSON file using fsnotify for append notifications.
// It handles the file not existing yet, rotation/truncation, and removal.
type Tailer struct {
	Path string // absolute or relative path to the NDJSON file to tail
}

// Run starts tailing t.Path.
//
//   - On startup it reads any pre-existing content and emits each parsed event.
//   - Then it watches for appends (fsnotify.Write) and emits new events.
//   - If the file does not exist, it waits for it to be created (watches parent dir).
//   - Truncation (file shrinks) is detected: offset resets to 0 and content is re-read.
//   - On removal the tailer re-enters the "wait for creation" state.
//   - Cancelling ctx stops the watcher and closes both returned channels.
//
// The errs channel is buffered (32); callers should drain it but not draining
// will never block the tailer.
func (t *Tailer) Run(ctx context.Context) (<-chan Event, <-chan error, error) {
	events := make(chan Event, 64)
	errs := make(chan error, 32)

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, nil, err
	}

	go func() {
		defer close(events)
		defer close(errs)
		defer watcher.Close()

		// sendErr pushes an error to the errs channel without blocking.
		sendErr := func(e error) {
			select {
			case errs <- e:
			default:
			}
		}

		absPath, err := filepath.Abs(t.Path)
		if err != nil {
			sendErr(err)
			return
		}
		parentDir := filepath.Dir(absPath)

		// offset tracks how many bytes of the file we have already consumed.
		var offset int64

		// readNewLines reads from the current offset to EOF, emitting events.
		// It returns the updated offset. On any IO error it reports to sendErr
		// and returns the unchanged offset.
		readNewLines := func(off int64) int64 {
			f, err := os.Open(absPath)
			if err != nil {
				if !errors.Is(err, fs.ErrNotExist) {
					sendErr(err)
				}
				return off
			}
			defer f.Close()

			// Detect truncation: if current file size < our offset, reset.
			fi, err := f.Stat()
			if err != nil {
				sendErr(err)
				return off
			}
			if fi.Size() < off {
				off = 0
			}

			if _, err := f.Seek(off, io.SeekStart); err != nil {
				sendErr(err)
				return off
			}

			scanner := bufio.NewScanner(f)
			for scanner.Scan() {
				line := scanner.Bytes()
				if len(line) == 0 {
					continue
				}
				ev, err := ParseEvent(line)
				if err != nil {
					sendErr(err)
				} else {
					select {
					case events <- ev:
					case <-ctx.Done():
						return off
					}
				}
			}
			if err := scanner.Err(); err != nil {
				sendErr(err)
			}
			// Advance offset to current position. We re-open to get a reliable
			// position rather than trying to track scanner bytes manually.
			newPos, err := f.Seek(0, io.SeekCurrent)
			if err == nil {
				off = newPos
			}
			return off
		}

		// watchFile attempts to add the target file to the watcher.
		// Returns true on success; on ErrNotExist watches the parent directory
		// instead and returns false.
		watchFile := func() bool {
			if err := watcher.Add(absPath); err != nil {
				if !errors.Is(err, fs.ErrNotExist) {
					sendErr(err)
				}
				// File not there yet — watch the parent so we see it appear.
				if werr := watcher.Add(parentDir); werr != nil {
					sendErr(werr)
				}
				return false
			}
			return true
		}

		// Initial state: try to watch the file; read existing content.
		fileExists := watchFile()
		if fileExists {
			offset = readNewLines(offset)
		}
		// If the file doesn't exist we are already watching the parent.

		for {
			select {
			case <-ctx.Done():
				return

			case event, ok := <-watcher.Events:
				if !ok {
					return
				}

				evPath := filepath.Clean(event.Name)

				switch {
				case event.Has(fsnotify.Write) && evPath == absPath:
					offset = readNewLines(offset)

				case event.Has(fsnotify.Create) && evPath == absPath:
					// File appeared (or was recreated after removal).
					// Reset offset so we read from the start of the new file.
					offset = 0
					// Switch from parent-dir watch to file watch.
					_ = watcher.Remove(parentDir)
					if err := watcher.Add(absPath); err != nil {
						sendErr(err)
					}
					offset = readNewLines(offset)

				case event.Has(fsnotify.Remove) && evPath == absPath:
					// File was removed — go back to watching the parent.
					offset = 0
					_ = watcher.Remove(absPath)
					if werr := watcher.Add(parentDir); werr != nil {
						sendErr(werr)
					}

				case event.Has(fsnotify.Rename) && evPath == absPath:
					// On some OSes rename fires instead of remove.
					offset = 0
					_ = watcher.Remove(absPath)
					if werr := watcher.Add(parentDir); werr != nil {
						sendErr(werr)
					}
				}

			case err, ok := <-watcher.Errors:
				if !ok {
					return
				}
				sendErr(err)
			}
		}
	}()

	return events, errs, nil
}
