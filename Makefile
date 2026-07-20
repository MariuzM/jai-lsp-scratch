VERSION    := $(shell node -p "require('./extension/package.json').version")
VSIX       := extension/jai-lsp-scratch-$(VERSION).vsix

build:
	jai server/build.jai - build

dev:
	watchexec -r -c -w server/src -w server/build.jai -e jai -- make build

bundle:
	jai server/build.jai - bundle

package: bundle
	cd extension && npx @vscode/vsce package

install: package
	code --install-extension $(VSIX)

release: package
	gh release create v$(VERSION) $(VSIX) --title "v$(VERSION)" --generate-notes 2>/dev/null || \
	gh release upload v$(VERSION) $(VSIX) --clobber

clean:
	jai server/build.jai - clean

.PHONY: build dev bundle package install release clean
