PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
UNITDIR ?= $(PREFIX)/lib/systemd/user
UDEVDIR ?= /etc/udev/rules.d
DESTDIR ?=

USER_BINDIR  ?= $(HOME)/.local/bin
USER_UNITDIR ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/systemd/user

.PHONY: all install install-udev install-user uninstall uninstall-user check test

all:
	@echo "targets: install (root), install-udev (root), install-user, uninstall, uninstall-user, check"

install:
	install -Dm755 framehaptix $(DESTDIR)$(BINDIR)/framehaptix
	install -dm755 $(DESTDIR)$(UNITDIR)
	sed 's|@BINDIR@|$(BINDIR)|' systemd/framehaptix.service > $(DESTDIR)$(UNITDIR)/framehaptix.service
	chmod 644 $(DESTDIR)$(UNITDIR)/framehaptix.service

install-udev:
	install -Dm644 udev/70-framehaptix.rules $(DESTDIR)$(UDEVDIR)/70-framehaptix.rules
	@if [ -z "$(DESTDIR)" ]; then \
		udevadm control --reload && udevadm trigger --subsystem-match=hidraw; fi

install-user:
	install -Dm755 framehaptix $(USER_BINDIR)/framehaptix
	install -dm755 $(USER_UNITDIR)
	sed 's|@BINDIR@|$(USER_BINDIR)|' systemd/framehaptix.service > $(USER_UNITDIR)/framehaptix.service
	@echo "now run: systemctl --user daemon-reload && systemctl --user enable --now framehaptix.service"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/framehaptix $(DESTDIR)$(UNITDIR)/framehaptix.service $(DESTDIR)$(UDEVDIR)/70-framehaptix.rules

uninstall-user:
	rm -f $(USER_BINDIR)/framehaptix $(USER_UNITDIR)/framehaptix.service

check test:
	bash -n framehaptix
	@if command -v shellcheck >/dev/null; then shellcheck framehaptix tests/run.sh; else echo "shellcheck not installed, skipping"; fi
	tests/run.sh
