CC ?= cc
CFLAGS ?= -std=c17 -O2 -Wall -Wextra -Werror -pedantic
LDLIBS ?= -lm -ldl -pthread
QMLLINT ?= /usr/lib/qt6/bin/qmllint

.PHONY: all build check test validate

all: build

build: bin/system-stats-helper

bin/system-stats-helper: src/system-stats-helper.c src/gpu-inventory.c src/gpu-inventory.h src/gpu-measurement.c src/gpu-measurement.h
	@mkdir -p bin
	$(CC) $(CFLAGS) src/system-stats-helper.c src/gpu-inventory.c src/gpu-measurement.c -o $@ $(LDLIBS)

check:
	$(CC) $(CFLAGS) -fsyntax-only src/system-stats-helper.c src/gpu-inventory.c src/gpu-measurement.c
	clang-format --dry-run --Werror src/system-stats-helper.c src/gpu-inventory.c src/gpu-inventory.h src/gpu-measurement.c src/gpu-measurement.h tests/native/fake_nvml.c tests/native/helper_observer.c tests/native/i915_pmu_probe.c tests/native/perf_event_fixture.c tests/native/scripted_helper.c
	$(QMLLINT) Service.qml

validate:
	bash tests/test_manifest.sh

test: build check validate
	bash tests/test_helper.sh
	bash tests/test_session.sh
	bash tests/test_ram.sh
	bash tests/test_configuration.sh
	bash tests/test_gpu_selection.sh
	bash tests/test_intel_gpu.sh
	bash tests/test_amd_gpu.sh
	bash tests/test_nvidia_gpu.sh
	bash tests/test_gpu_integration.sh
	bash tests/test_gpu_persistence.sh
	bash tests/test_freshness.sh
	bash tests/test_protocol.sh
	bash tests/test_supervision.sh
	bash tests/test_widget.sh
