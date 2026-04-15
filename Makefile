PACKAGES := shared oracle diamond hook exchange router

.PHONY: all build test test-fork fmt clean $(PACKAGES)

all: build

build:
	@for p in $(PACKAGES); do \
		echo "==> build $$p"; \
		$(MAKE) -C packages/$$p build || exit 1; \
	done

test:
	@for p in $(PACKAGES); do \
		echo "==> test $$p"; \
		$(MAKE) -C packages/$$p test || exit 1; \
	done

# Fork tests against a live chain RPC. Requires UNICHAIN_RPC_PRIMARY plus
# the chain-specific addresses in the shell environment. See SC/FORK_TESTS.md
# for the env matrix and per-package coverage. Fork tests are intentionally
# off the default test path (no network in CI by default).
test-fork:
	@for p in $(PACKAGES); do \
		echo "==> fork-test $$p"; \
		(cd packages/$$p && forge test --match-path 'test/fork/*' || exit 1); \
	done

fmt:
	@for p in $(PACKAGES); do \
		(cd packages/$$p && forge fmt); \
	done

clean:
	@for p in $(PACKAGES); do \
		(cd packages/$$p && forge clean); \
	done

$(PACKAGES):
	$(MAKE) -C packages/$@ build
