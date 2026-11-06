# mapconv build and test entry points.
# Requires Odin (https://odin-lang.org). Set ODIN=/path/to/odin.exe when the
# compiler is not on PATH.

ODIN ?= odin
BIN  := mapconv.exe

# Packages in dependency order; those without *_test.odin are skipped.
PACKAGES := geom xform ir diag profile kv vmf bsp t3d ue3 convert

.PHONY: all build test test-verbose clean fmt

all: build test

build:
	@mkdir -p build
	$(ODIN) build . -out:$(BIN)

# Tests run from the module root so fixtures resolve as tests/fixtures/...
test:
	@mkdir -p build
	@fail=0; for p in $(PACKAGES); do \
		if ! ls $$p/*_test.odin > /dev/null 2>&1; then \
			printf "%-8s no tests\n" "$$p"; continue; \
		fi; \
		printf "%-8s " "$$p"; \
		if $(ODIN) test $$p -define:ODIN_TEST_THREADS=1 > build/$$p.test.log 2>&1; then \
			grep -E "^Finished" build/$$p.test.log | tail -1; \
		else \
			fail=1; echo "FAILED — see build/$$p.test.log"; \
			grep -E "FAIL|Error:" build/$$p.test.log | head -5; \
		fi; \
	done; exit $$fail

test-verbose:
	@mkdir -p build
	@for p in $(PACKAGES); do \
		ls $$p/*_test.odin > /dev/null 2>&1 || continue; \
		echo "== $$p"; $(ODIN) test $$p -define:ODIN_TEST_THREADS=1 || exit 1; done

fmt:
	$(ODIN) fmt -w .

clean:
	rm -rf build $(BIN)
