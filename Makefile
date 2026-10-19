# Build output lives outside ~/Documents: iCloud Drive syncs this folder and
# adds file-provider attributes that break code signing (and would upload
# every build to iCloud).
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
BUILD_ROOT    ?= $(HOME)/Library/Caches/Converter
CORE          := Packages/ConverterCore
CORE_BUILD    := $(BUILD_ROOT)/ConverterCore
SWIFT         := DEVELOPER_DIR=$(DEVELOPER_DIR) swift

.PHONY: core core-test cli project app app-test run test readme-images release publish clean

core:
	$(SWIFT) build --package-path $(CORE) --scratch-path $(CORE_BUILD)

core-test: core
	$(SWIFT) test --package-path $(CORE) --scratch-path $(CORE_BUILD)

# Prints the path of the built CLI, e.g. `$(make -s cli) list photo.heic`.
cli:
	@$(SWIFT) build --package-path $(CORE) --scratch-path $(CORE_BUILD) >&2
	@echo $$($(SWIFT) build --package-path $(CORE) --scratch-path $(CORE_BUILD) --show-bin-path)/swivel

# --- App ------------------------------------------------------------------
APP_BUILD     := $(BUILD_ROOT)/DerivedData
APP           := $(APP_BUILD)/Build/Products/Debug/Swivel.app
# Drops Xcode log noise unrelated to this project.
NOISE         := iOSSimulator|appintentsmetadataprocessor|com\.apple\.linkd
XCODEBUILD    := DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project Converter/Converter.xcodeproj \
                 -scheme Converter -configuration Debug -derivedDataPath $(APP_BUILD)

project:
	cd Converter && xcodegen generate --quiet

app: project
	@set -o pipefail; $(XCODEBUILD) build 2>&1 | grep -vE "$(NOISE)" | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"

app-test: project
	@set -o pipefail; $(XCODEBUILD) test 2>&1 | grep -vE "$(NOISE)" | grep -E "error:|warning:|Test Case.*failed|Executed|TEST (SUCCEEDED|FAILED)"

# Quits a running copy, then launches the fresh build.
run: app
	-pkill -x Swivel; sleep 0.5
	open "$(APP)"

test: core-test app-test

# Renders the README's pictures from the app's own views into docs/images.
README_IMAGES := $(CURDIR)/docs/images
readme-images: project
	@set -o pipefail; TEST_RUNNER_README_IMAGES=$(README_IMAGES) $(XCODEBUILD) test \
		-only-testing:ConverterTests/ReadmeImageTests 2>&1 | grep -vE "$(NOISE)" \
		| grep -E "error:|Test Case.*(passed|failed)|TEST (SUCCEEDED|FAILED)"
	sips -s format png --resampleWidth 256 "$(APP)/Contents/Resources/AppIcon.icns" \
		--out $(README_IMAGES)/icon.png >/dev/null
	sips -s format png --resampleWidth 1024 "$(APP)/Contents/Resources/AppIcon.icns" \
		--out $(README_IMAGES)/icon-1024.png >/dev/null

# Signed, notarized Swivel.dmg for a GitHub release (docs/dev/releasing.md).
release:
	./scripts/release.sh

# Publishes that DMG: GitHub release, changelog date, Homebrew tap.
publish:
	./scripts/publish.sh

clean:
	rm -rf $(BUILD_ROOT)
