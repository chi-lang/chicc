# Makefile for Chi self-hosting compiler (chicc)
#
# Main targets:
#   make              Build chicc.lua (default)
#   make test         Run all tests
#   make test-<file>  Run specific test file (e.g. make test-lexer)
#   make native       Build native chi binary (requires CHI_HOME set)
#   make verify       Verify fixed-point compilation
#   make clean        Remove generated files
#   make distclean    Full clean + remove .cache and native build
#   make install      Install native binary to CHI_HOME/bin
#
# Environment variables:
#   CHI              Compiler to use (default: chi)
#   CHI_HOME         Installation directory (required for native builds)

.PHONY: all build test test-% native verify clean distclean install help

# Default target
all: chicc.lua

# Defaults
CHI ?= chi
SHELL := /bin/bash

# ============================================================================
# Build chicc.lua
# ============================================================================

chicc.lua: compile.chi
	@echo "Building chicc.lua..."
	rm -rf .cache
	$(CHI) compile.chi
	@echo "✓ chicc.lua built successfully"

.PHONY: build
build: chicc.lua

# ============================================================================
# Testing
# ============================================================================

.PHONY: test
test: chicc.lua
	@echo "Running test suite..."
	@./run_tests.sh

# Run a specific test file by name (e.g., make test-lexer → runs tests/test_lexer.chi)
.PHONY: test-%
test-%: chicc.lua
	@echo "Running tests/$*.chi..."
	@./run_tests.sh tests/test_$*.chi

# ============================================================================
# Native Compiler
# ============================================================================

.PHONY: native
native: chicc.lua
	@echo "Building native chi binary..."
	@if [ -z "$(CHI_HOME)" ]; then \
		echo "Error: CHI_HOME not set. Please set CHI_HOME to your Chi installation directory."; \
		exit 1; \
	fi
	$(MAKE) -C native clean
	$(MAKE) -C native

.PHONY: install
install: native
	$(MAKE) -C native install

# ============================================================================
# Verification & Quality
# ============================================================================

.PHONY: verify
verify: chicc.lua
	@echo "Verifying fixed-point compilation..."
	@bash fixed_point_verification.sh

# ============================================================================
# Cleaning
# ============================================================================

.PHONY: clean
clean:
	@echo "Cleaning generated files..."
	rm -f chicc.lua
	$(MAKE) -C native clean 2>/dev/null || true

.PHONY: distclean
distclean: clean
	@echo "Full clean (including cache and native builds)..."
	rm -rf .cache
	$(MAKE) -C native distclean 2>/dev/null || true
	@echo "✓ Project cleaned"

# ============================================================================
# Help
# ============================================================================

.PHONY: help
help:
	@echo "Chi Compiler (chicc) — Build System"
	@echo ""
	@echo "Main targets:"
	@echo "  make              Build chicc.lua (default)"
	@echo "  make test         Run all tests"
	@echo "  make test-<file>  Run specific test (e.g., make test-lexer)"
	@echo "  make native       Build native chi binary"
	@echo "  make install      Install native binary"
	@echo "  make verify       Verify fixed-point compilation"
	@echo "  make clean        Remove generated files"
	@echo "  make distclean    Full clean including cache"
	@echo ""
	@echo "Example usage:"
	@echo "  make                    # Build chicc.lua"
	@echo "  CHI_HOME=~/.chi make    # Set CHI_HOME for native builds"
	@echo "  make native install     # Build and install native compiler"
	@echo ""
