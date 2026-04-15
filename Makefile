PACKAGES := shared oracle diamond hook exchange router

.PHONY: all build test fmt clean $(PACKAGES)

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
