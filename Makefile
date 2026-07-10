SERVER_BIN := server/build/jai-lsp-scratch
BUNDLED    := extension/bin/jai-lsp-scratch-darwin-arm64
VERSION    := $(shell node -p "require('./extension/package.json').version")
VSIX       := extension/jai-lsp-scratch-$(VERSION).vsix

build:
	cd server && jai build.jai

dev:
	watchexec -r -c -w server -e jai -- make build

bundle: build
	mkdir -p extension/bin
	cp $(SERVER_BIN) $(BUNDLED)

package: bundle
	cd extension && npx @vscode/vsce package

install: package
	code --install-extension $(VSIX)

release: package
	gh release create v$(VERSION) $(VSIX) --title "v$(VERSION)" --generate-notes 2>/dev/null || \
	gh release upload v$(VERSION) $(VSIX) --clobber

clean:
	rm -rf server/build extension/*.vsix

.PHONY: build dev bundle package install release clean
