.PHONY: build test run dist notarize brand
build:
	bash scripts/build.sh
brand:
	bash scripts/export-brand.sh
test:
	swift test
run: build
	open build/MacClaude.app
dist: build
	ditto -c -k --keepParent build/MacClaude.app build/MacClaude.zip
notarize:
	bash scripts/notarize.sh
