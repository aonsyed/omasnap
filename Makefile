BUILD_DIR ?= build
BUILD_TYPE ?= Release
PREFIX ?= $(HOME)/.local
GENERATOR ?= Ninja

CMAKE ?= cmake
CMAKE_ARGS ?=
CLANG_TIDY ?= clang-tidy
CLAZY ?= clazy-standalone
QMLLINT ?= qmllint
CLANG_FORMAT ?= clang-format
DOXYGEN ?= doxygen

LINT_SOURCES := $(wildcard src/*.cpp tests/*.cpp)
LINT_CHECKS ?= -*,clang-analyzer-*,bugprone-*,performance-*,misc-*
FORMAT_SOURCES := $(wildcard src/*.cpp src/*.hpp src/*.mm tests/*.cpp tests/*.hpp)

.PHONY: all configure build clean install check smoke lint qt-lint format \
	format-check docs todo-scan size-scan unused-deps-check \
	feature-flag-check agents-md-check guards

all: build

configure:
	$(CMAKE) -S . -B $(BUILD_DIR) -G $(GENERATOR) \
		-DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
		-DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
		-DCMAKE_INSTALL_PREFIX=$(PREFIX) \
		$(CMAKE_ARGS)

build: configure
	$(CMAKE) --build $(BUILD_DIR) --parallel

smoke: build
	QT_QPA_PLATFORM=offscreen $(BUILD_DIR)/omasnap-smoke \
		$(BUILD_DIR)/omasnap-smoke-output

lint: build
	@set -eu; \
	if command -v "$(CLANG_TIDY)" >/dev/null 2>&1; then \
		commands_dir=$$(mktemp -d); \
		trap 'rm -rf "$$commands_dir"' EXIT; \
		cp "$(BUILD_DIR)/compile_commands.json" \
			"$$commands_dir/compile_commands.json"; \
		sed -e 's/ -mno-direct-extern-access//g' \
			"$$commands_dir/compile_commands.json" \
			> "$$commands_dir/compile_commands.json.filtered"; \
		mv "$$commands_dir/compile_commands.json.filtered" \
			"$$commands_dir/compile_commands.json"; \
		for source in $(LINT_SOURCES); do \
			"$(CLANG_TIDY)" -p "$$commands_dir" \
				-checks="$(LINT_CHECKS)" -header-filter='.*' "$$source"; \
		done; \
	else \
		echo "make check: clang-tidy unavailable; skipping"; \
	fi

qt-lint: build
	@set -eu; \
	if command -v "$(CLAZY)" >/dev/null 2>&1; then \
		for source in $(LINT_SOURCES); do \
			"$(CLAZY)" -p "$(BUILD_DIR)" "$$source"; \
		done; \
	else \
		echo "make check: clazy unavailable; skipping Qt-specific clazy pass"; \
	fi; \
	if command -v "$(QMLLINT)" >/dev/null 2>&1 && test -d qml; then \
		"$(QMLLINT)" qml; \
	else \
		echo "make check: no QML sources or qmllint unavailable; skipping"; \
	fi

check: smoke lint qt-lint guards

format:
	@if command -v "$(CLANG_FORMAT)" >/dev/null 2>&1; then \
		"$(CLANG_FORMAT)" -i $(FORMAT_SOURCES); \
	else \
		echo "make format: clang-format unavailable; skipping"; \
	fi

format-check:
	@if command -v "$(CLANG_FORMAT)" >/dev/null 2>&1; then \
		"$(CLANG_FORMAT)" --dry-run --Werror $(FORMAT_SOURCES); \
	else \
		echo "make format-check: clang-format unavailable; skipping"; \
	fi

docs:
	@if command -v "$(DOXYGEN)" >/dev/null 2>&1; then \
		"$(DOXYGEN)" Doxyfile; \
		echo "make docs: HTML reference written to build/docs/html"; \
	else \
		echo "make docs: doxygen unavailable; skipping"; \
	fi

todo-scan:
	scripts/scan-todos.sh

size-scan:
	scripts/check-large-files.sh

unused-deps-check:
	scripts/check-unused-deps.sh

feature-flag-check:
	scripts/check-feature-flags.sh

agents-md-check:
	scripts/validate-agents-md.sh

guards: todo-scan size-scan unused-deps-check feature-flag-check agents-md-check

clean:
	@if test -d "$(BUILD_DIR)"; then \
		$(CMAKE) --build "$(BUILD_DIR)" --target clean; \
	fi

install: build
	$(CMAKE) --install $(BUILD_DIR)
