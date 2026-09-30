.PHONY: build test run dist notarize
build:
	bash scripts/build.sh
test:
	swift test
run: build
	open build/MacClaude.app
dist: build
	ditto -c -k --keepParent build/MacClaude.app build/MacClaude.zip
notarize:
	bash scripts/notarize.sh
