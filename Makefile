.PHONY: tui tui-install tui-dev tui-clean tui-test

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
