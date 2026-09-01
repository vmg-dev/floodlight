.PHONY: build bundle clean debug dmg docs icons install run test

debug:
	swift build

build:
	swift build -c release

run: debug
	./scripts/run.sh

test:
	swift test --package-path Vendor/fff-swift
	swift test

bundle: build
	./scripts/bundle.sh

icons:
	./scripts/build-app-icon.sh

dmg: bundle
	./scripts/create-dmg.sh

docs:
	npm --prefix docs run build

install: bundle
	./scripts/install.sh

clean:
	swift package clean
