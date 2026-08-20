CC ?= cc
CFLAGS ?= -std=c17 -O2 -Wall -Wextra -Werror -pedantic
QMLLINT ?= /usr/lib/qt6/bin/qmllint

.PHONY: all build check test validate

all: build

build: bin/system-stats-helper

bin/system-stats-helper: src/system-stats-helper.c
	@mkdir -p bin
	$(CC) $(CFLAGS) $< -o $@ -lm

check:
	$(CC) $(CFLAGS) -fsyntax-only src/system-stats-helper.c
	clang-format --dry-run --Werror src/system-stats-helper.c tests/native/helper_observer.c tests/native/scripted_helper.c
	$(QMLLINT) Service.qml

validate:
	bash tests/test_manifest.sh

test: build check validate
	bash tests/test_helper.sh
	bash tests/test_session.sh
	bash tests/test_configuration.sh
	bash tests/test_freshness.sh
	bash tests/test_protocol.sh
	bash tests/test_supervision.sh
	bash tests/test_widget.sh
