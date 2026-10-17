IMAGE := borg-relay-test
RUN   := podman run --rm -v $(CURDIR):/src:Z -w /src $(IMAGE)

.PHONY: image test lint check
image:
	podman build -q -t $(IMAGE) -f tests/Containerfile tests >/dev/null
test: image
	$(RUN) bats tests
lint: image
	$(RUN) tests/lint.sh
check: lint test
