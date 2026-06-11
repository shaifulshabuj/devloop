# go build/test must run inside cmd/devloop-tui (go.work only lists that module).
# Use these top-level targets instead of `go build ./...` from the repo root.
.PHONY: build test tui tui-install tui-dev tui-clean tui-test

build: tui

test: tui-test

tui:
	$(MAKE) -C cmd/devloop-tui build

tui-install:
	$(MAKE) -C cmd/devloop-tui install

tui-dev:
	$(MAKE) -C cmd/devloop-tui dev

tui-clean:
	$(MAKE) -C cmd/devloop-tui clean

tui-test:
	$(MAKE) -C cmd/devloop-tui test
