BINARY   = export-notes
SOURCES  = export-notes.swift Version.swift

GIT_DESC := $(shell git describe --tags --long 2>/dev/null || echo "v0.0.0-0-gunknown")
# v1.0.0-2-ga905934 → 1.0.0+2.a905934  (strip v prefix, reformat)
# v1.0.0-0-gabcdef1 → 1.0.0             (clean tag, no suffix)
VERSION  := $(shell V="$(GIT_DESC)"; V="$${V\#v}"; \
	COMMITS=$$(echo "$$V" | sed 's/.*-\([0-9]*\)-g.*/\1/'); \
	HASH=$$(echo "$$V" | sed 's/.*-g//'); \
	BASE=$$(echo "$$V" | sed 's/-[0-9]*-g.*//'); \
	if [ "$$COMMITS" = "0" ]; then echo "$$BASE"; else echo "$$BASE+$$COMMITS.$$HASH"; fi)

.PHONY: all clean version Version.swift

all: $(BINARY)

Version.swift:
	@echo 'let appVersion = "$(VERSION)"' > Version.swift

$(BINARY): export-notes.swift Version.swift
	@ln -sf export-notes.swift main.swift
	swiftc -framework ScriptingBridge main.swift Version.swift -o $(BINARY)
	@rm -f main.swift

clean:
	rm -f $(BINARY) Version.swift

version:
	@echo $(VERSION)
