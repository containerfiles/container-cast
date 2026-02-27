# Colors
GREEN := \033[32m
CYAN := \033[36m
YELLOW := \033[33m
GRAY := \033[90m
BOLD := \033[1m
RESET := \033[0m

# Config
BIN_DIR := /usr/local/bin
LIB_DIR := /usr/local/libexec/container-cast
PLUGIN_DIR := /usr/local/libexec/container/plugins/cast
COMPLETIONS_DIR := $(shell zsh -c 'for d in $${fpath}; do if [[ "$$d" == $(HOME)/* ]] && [[ -d "$$d" ]] && [[ -w "$$d" ]]; then echo "$$d"; exit 0; fi; done; echo "$(HOME)/Library/Application Support/zsh/completions"')

.DEFAULT_GOAL := help
.PHONY: build install uninstall plugin unplug health clean rebuild test completions help

# ============================================================
# Build
# ============================================================
build:
	@echo "Building container-cast..."
	@swift build -c release
	@codesign --force --sign - --timestamp=none --entitlements container-cast.entitlements .build/release/container-cast
	@codesign --force --sign - --timestamp=none --entitlements container-cast.entitlements .build/release/container-cast-runner
	@echo "$(GREEN)Build complete!$(RESET)"

# ============================================================
# Install
# ============================================================
install: completions
	@if [ ! -f .build/release/container-cast ]; then \
		echo "$(YELLOW)No binary found.$(RESET) Run 'make build' first."; \
		exit 1; \
	fi
	@mkdir -p $(BIN_DIR) $(LIB_DIR)
	@echo "Installing container-cast to $(BIN_DIR)..."
	@if [ -f $(BIN_DIR)/container-cast ]; then rm $(BIN_DIR)/container-cast; fi
	@cp .build/release/container-cast $(BIN_DIR)/container-cast
	@echo "Installing container-cast-runner to $(LIB_DIR)..."
	@if [ -f $(LIB_DIR)/container-cast-runner ]; then rm $(LIB_DIR)/container-cast-runner; fi
	@cp .build/release/container-cast-runner $(LIB_DIR)/container-cast-runner
	@echo "$(GREEN)Installed!$(RESET)"

# ============================================================
# Plugin (register as `container cast`)
# ============================================================
plugin:
	@if [ ! -f .build/release/container-cast ] || [ ! -f .build/release/container-cast-runner ]; then \
		echo "$(YELLOW)No binaries found.$(RESET) Run 'make build' first."; \
		exit 1; \
	fi
	@mkdir -p "$(PLUGIN_DIR)/bin"
	@cp .build/release/container-cast "$(PLUGIN_DIR)/bin/cast"
	@cp .build/release/container-cast-runner "$(PLUGIN_DIR)/bin/container-cast-runner"
	@cp plugin.json "$(PLUGIN_DIR)/config.json"
	@echo "$(GREEN)Plugin installed!$(RESET) Run $(CYAN)container cast$(RESET) to use."

# ============================================================
# Unplug (remove container plugin)
# ============================================================
unplug:
	@if [ -d "$(PLUGIN_DIR)" ]; then \
		rm -rf "$(PLUGIN_DIR)"; \
		echo "$(GREEN)Plugin removed.$(RESET)"; \
	else \
		echo "$(YELLOW)Plugin not installed.$(RESET)"; \
	fi

# ============================================================
# Uninstall
# ============================================================
uninstall:
	@if [ -f $(BIN_DIR)/container-cast ]; then \
		echo "Removing $(BIN_DIR)/container-cast..."; \
		rm $(BIN_DIR)/container-cast; \
	else \
		echo "$(YELLOW)container-cast not found in $(BIN_DIR).$(RESET)"; \
	fi
	@if [ -d $(LIB_DIR) ]; then \
		echo "Removing $(LIB_DIR)..."; \
		rm -rf $(LIB_DIR); \
	fi
	@if [ -f "$(COMPLETIONS_DIR)/_container-cast" ]; then \
		echo "Removing $(COMPLETIONS_DIR)/_container-cast..."; \
		rm "$(COMPLETIONS_DIR)/_container-cast"; \
	fi
	@if [ -d "$(PLUGIN_DIR)" ]; then \
		echo "Removing container plugin..."; \
		rm -rf "$(PLUGIN_DIR)"; \
	fi
	@echo "$(GREEN)Uninstalled!$(RESET)"

# ============================================================
# Health
# ============================================================
health:
	@if [ -x $(BIN_DIR)/container-cast ]; then \
		echo "$(GREEN)container-cast installed$(RESET)"; \
	else \
		echo "$(YELLOW)container-cast not installed$(RESET)"; \
		exit 1; \
	fi
	@if [ -x $(LIB_DIR)/container-cast-runner ]; then \
		echo "$(GREEN)container-cast-runner installed$(RESET)"; \
	else \
		echo "$(YELLOW)container-cast-runner not installed$(RESET)"; \
		exit 1; \
	fi

# ============================================================
# Rebuild (clean + build + install)
# ============================================================
rebuild: clean build plugin

# ============================================================
# Test
# ============================================================
test:
	@swift test

# ============================================================
# Clean
# ============================================================
clean:
	@echo "Cleaning build artifacts..."
	@swift package clean
	@rm -rf .build
	@echo "$(GREEN)Done!$(RESET)"

# ============================================================
# Completions
# ============================================================
completions:
	@if [ ! -f .build/release/container-cast ]; then \
		echo "$(YELLOW)No binary found.$(RESET) Run 'make build' first."; \
		exit 1; \
	fi
	@mkdir -p "$(COMPLETIONS_DIR)"
	@.build/release/container-cast completions > "$(COMPLETIONS_DIR)/_container-cast"
	@echo "$(GREEN)Completions installed to $(COMPLETIONS_DIR)$(RESET)"
	@zsh -ic 'for d in $$fpath; do [ "$$d" = "$(COMPLETIONS_DIR)" ] && exit 0; done; exit 1' 2>/dev/null \
		|| echo "$(YELLOW)Warning:$(RESET) $(COMPLETIONS_DIR) is not in your fpath"

# ============================================================
# Help
# ============================================================
help:
	@echo ""
	@echo "$(BOLD)Usage:$(RESET) make $(CYAN)[target]$(RESET)"
	@echo ""
	@echo "$(YELLOW)Targets:$(RESET)"
	@echo "  $(CYAN)build$(RESET)        $(GRAY)-$(RESET) $(GREEN)Build both binaries (container-cast + container-cast-runner)$(RESET)"
	@echo "  $(CYAN)install$(RESET)      $(GRAY)-$(RESET) $(GREEN)Install container-cast to /usr/local/bin, runner to /usr/local/libexec$(RESET)"
	@echo "  $(CYAN)plugin$(RESET)       $(GRAY)-$(RESET) $(GREEN)Register as 'container cast' plugin$(RESET)"
	@echo "  $(CYAN)unplug$(RESET)       $(GRAY)-$(RESET) $(GREEN)Remove container plugin$(RESET)"
	@echo "  $(CYAN)rebuild$(RESET)      $(GRAY)-$(RESET) $(GREEN)Clean, build, and register plugin$(RESET)"
	@echo "  $(CYAN)uninstall$(RESET)    $(GRAY)-$(RESET) $(GREEN)Remove all installed binaries and plugin$(RESET)"
	@echo "  $(CYAN)health$(RESET)       $(GRAY)-$(RESET) $(GREEN)Check if binaries are installed$(RESET)"
	@echo "  $(CYAN)test$(RESET)         $(GRAY)-$(RESET) $(GREEN)Run tests$(RESET)"
	@echo "  $(CYAN)completions$(RESET)  $(GRAY)-$(RESET) $(GREEN)Generate zsh completions$(RESET)"
	@echo "  $(CYAN)clean$(RESET)        $(GRAY)-$(RESET) $(GREEN)Remove build artifacts$(RESET)"
	@echo "  $(CYAN)help$(RESET)         $(GRAY)-$(RESET) $(GREEN)Show this help message (default)$(RESET)"
	@echo ""
