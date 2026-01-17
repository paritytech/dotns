.PHONY: \
  ensure-toolchain \
  contracts-fmt contracts-fmt-check contracts-fmt-rs contracts-fmt-rs-check contracts-fmt-toml contracts-fmt-toml-check contracts-lint-toml contracts-build contracts-test contracts-clean contracts-check \
  fuzzer-fmt fuzzer-fmt-check fuzzer-fmt-rs fuzzer-fmt-rs-check fuzzer-fmt-toml fuzzer-fmt-toml-check fuzzer-lint-toml fuzzer-build fuzzer-test fuzzer-clean fuzzer-check \
  install-tools help

TOOLCHAIN ?= nightly-2025-09-22

CONTRACT_DIRS := $(wildcard contracts/*/)
FUZZER_DIR := fuzzer

define RUN_IF_CARGO_TOML
	@if [ -f "$(1)/Cargo.toml" ]; then \
		echo "$(2) $(1)"; \
		(cd "$(1)" && $(3)); \
	fi
endef

ensure-toolchain:
	@echo "Ensuring Rust toolchain: $(TOOLCHAIN)"
	@rustup toolchain install $(TOOLCHAIN)
	@rustup component add rust-src --toolchain $(TOOLCHAIN)
	@echo "Toolchain ready: $(TOOLCHAIN)"

contracts-fmt: contracts-fmt-rs contracts-fmt-toml
	@echo "Contracts formatting complete!"

contracts-fmt-check: contracts-fmt-rs-check contracts-fmt-toml-check
	@echo "Contracts formatting checks passed!"

contracts-fmt-rs:
	@echo "Formatting contracts Rust files..."
	@for dir in $(CONTRACT_DIRS); do \
		$(call RUN_IF_CARGO_TOML,$$dir,Formatting,(cargo +stable fmt)); \
	done

contracts-fmt-rs-check:
	@echo "Checking contracts Rust formatting..."
	@for dir in $(CONTRACT_DIRS); do \
		$(call RUN_IF_CARGO_TOML,$$dir,Checking,(cargo +stable fmt --check)); \
	done

contracts-fmt-toml:
	@echo "Formatting contracts TOML files..."
	@taplo fmt "contracts/**/Cargo.toml"

contracts-fmt-toml-check:
	@echo "Checking contracts TOML formatting..."
	@taplo fmt --check "contracts/**/Cargo.toml"

contracts-lint-toml:
	@echo "Linting contracts TOML files..."
	@taplo lint "contracts/**/Cargo.toml"

contracts-build: ensure-toolchain
	@echo "Building contracts with $(TOOLCHAIN)..."
	@for dir in $(CONTRACT_DIRS); do \
		$(call RUN_IF_CARGO_TOML,$$dir,Building,(RUSTUP_TOOLCHAIN=$(TOOLCHAIN) pop build --release)); \
	done

contracts-test: ensure-toolchain
	@echo "Testing contracts with $(TOOLCHAIN)..."
	@for dir in $(CONTRACT_DIRS); do \
		$(call RUN_IF_CARGO_TOML,$$dir,Testing,(RUSTUP_TOOLCHAIN=$(TOOLCHAIN) pop test)); \
	done

contracts-clean:
	@echo "Cleaning contracts..."
	@for dir in $(CONTRACT_DIRS); do \
		$(call RUN_IF_CARGO_TOML,$$dir,Cleaning,(cargo clean)); \
	done

contracts-check: contracts-fmt-check contracts-lint-toml contracts-test
	@echo "Contracts checks passed!"

fuzzer-fmt: fuzzer-fmt-rs fuzzer-fmt-toml
	@echo "Fuzzer formatting complete!"

fuzzer-fmt-check: fuzzer-fmt-rs-check fuzzer-fmt-toml-check
	@echo "Fuzzer formatting checks passed!"

fuzzer-fmt-rs:
	@echo "Formatting fuzzer Rust files..."
	@$(call RUN_IF_CARGO_TOML,$(FUZZER_DIR),Formatting,(cargo +stable fmt))

fuzzer-fmt-rs-check:
	@echo "Checking fuzzer Rust formatting..."
	@$(call RUN_IF_CARGO_TOML,$(FUZZER_DIR),Checking,(cargo +stable fmt --check))

fuzzer-fmt-toml:
	@echo "Formatting fuzzer TOML files..."
	@if [ -f "$(FUZZER_DIR)/Cargo.toml" ]; then taplo fmt "$(FUZZER_DIR)/**/Cargo.toml"; fi

fuzzer-fmt-toml-check:
	@echo "Checking fuzzer TOML formatting..."
	@if [ -f "$(FUZZER_DIR)/Cargo.toml" ]; then taplo fmt --check "$(FUZZER_DIR)/**/Cargo.toml"; fi

fuzzer-lint-toml:
	@echo "Linting fuzzer TOML files..."
	@if [ -f "$(FUZZER_DIR)/Cargo.toml" ]; then taplo lint "$(FUZZER_DIR)/**/Cargo.toml"; fi

fuzzer-build: ensure-toolchain
	@echo "Building fuzzer with $(TOOLCHAIN)..."
	@$(call RUN_IF_CARGO_TOML,$(FUZZER_DIR),Building,(RUSTUP_TOOLCHAIN=$(TOOLCHAIN) cargo build))

fuzzer-test: ensure-toolchain
	@echo "Testing fuzzer with $(TOOLCHAIN)..."
	@$(call RUN_IF_CARGO_TOML,$(FUZZER_DIR),Testing,(RUSTUP_TOOLCHAIN=$(TOOLCHAIN) cargo test))

fuzzer-clean:
	@echo "Cleaning fuzzer..."
	@$(call RUN_IF_CARGO_TOML,$(FUZZER_DIR),Cleaning,(cargo clean))

fuzzer-check: fuzzer-fmt-check fuzzer-lint-toml fuzzer-test
	@echo "Fuzzer checks passed!"

install-tools:
	@echo "Installing formatting tools..."
	@cargo install taplo-cli
	@rustup component add rustfmt
	@echo "Tools installed!"

help:
	@echo "Available targets:"
	@echo "  ensure-toolchain          - Install $(TOOLCHAIN) + rust-src"
	@echo "  contracts-build           - Build contracts (pop build)"
	@echo "  contracts-test            - Test contracts (pop test)"
	@echo "  contracts-clean           - Clean contracts"
	@echo "  contracts-fmt             - Format contracts (.rs + Cargo.toml)"
	@echo "  contracts-fmt-check       - Check formatting for contracts"
	@echo "  contracts-lint-toml       - Taplo lint for contracts"
	@echo "  contracts-check           - fmt-check + lint-toml + test (contracts)"
	@echo "  fuzzer-build              - Build fuzzer (cargo build)"
	@echo "  fuzzer-test               - Test fuzzer (cargo test)"
	@echo "  fuzzer-clean              - Clean fuzzer"
	@echo "  fuzzer-fmt                - Format fuzzer (.rs + Cargo.toml)"
	@echo "  fuzzer-fmt-check          - Check formatting for fuzzer"
	@echo "  fuzzer-lint-toml          - Taplo lint for fuzzer"
	@echo "  fuzzer-check              - fmt-check + lint-toml + test (fuzzer)"
	@echo "  install-tools             - Install taplo and rustfmt"
	@echo "  help                      - Show this help message"
