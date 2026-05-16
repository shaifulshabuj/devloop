.PHONY: build install dev clean test

BUILD_DIR := ./bin
BINARY    := $(BUILD_DIR)/devloop-tui
INSTALL_DIR := $(HOME)/.devloop/bin

build:
	go build -o $(BINARY) .

install: build
	mkdir -p $(INSTALL_DIR)
	cp $(BINARY) $(INSTALL_DIR)/devloop-tui

dev:
	go run . $(ARGS)

clean:
	rm -rf $(BUILD_DIR)

test:
	go test ./...
