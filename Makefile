# Copyright 2026 Кислов Роман Сергеевич
# SPDX-License-Identifier: Apache-2.0

APP := build/gscaller.app

.PHONY: build test run clean
build:
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	MACOSX_DEPLOYMENT_TARGET=12.0 CGO_CFLAGS="-O2 -g -mmacosx-version-min=12.0" CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o $(APP)/Contents/MacOS/gscaller .
	cp packaging/Info.plist $(APP)/Contents/Info.plist
	cp LICENSE NOTICE $(APP)/Contents/Resources/
	cp "$$(go env GOROOT)/LICENSE" $(APP)/Contents/Resources/GO-LICENSE
	codesign --force --sign - $(APP)

test:
	MACOSX_DEPLOYMENT_TARGET=12.0 CGO_CFLAGS="-O2 -g -mmacosx-version-min=12.0" go test -race ./...
	MACOSX_DEPLOYMENT_TARGET=12.0 CGO_CFLAGS="-O2 -g -mmacosx-version-min=12.0" go vet ./...

run: build
	open $(APP)

clean:
	rm -rf build

.PHONY: release
release: test build
	mkdir -p build/release
	ditto -c -k --norsrc --noextattr --noqtn --keepParent $(APP) build/release/gscaller-0.1.1-macos-$$(go env GOARCH).zip
	cd build/release && shasum -a 256 gscaller-0.1.1-macos-$$(go env GOARCH).zip > SHA256SUMS.txt
