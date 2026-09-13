.PHONY: run build deploy clean release

APP = build/Nodio.app
BIN = .build/debug/VoxType
DMG = build/Nodio.dmg
DMG_STAGING = build/dmg-staging
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" VoxType/Info.plist)

run: build
	@echo "→ Launching Nodio…"
	@open "$(APP)"

build:
	@echo "→ Building Nodio…"
	@swift build
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp .build/debug/VoxType "$(APP)/Contents/MacOS/Nodio"
	@cp VoxType/Info.plist "$(APP)/Contents/Info.plist"
	@cp VoxType/AppIcon.icns "$(APP)/Contents/Resources/" 2>/dev/null || true
	@cp VoxType/Resources/mic.svg "$(APP)/Contents/Resources/" 2>/dev/null || true
	@codesign --force --deep --sign - --identifier com.nodio.app \
		--entitlements VoxType/Nodio.entitlements "$(APP)"
	@echo "→ Built $(APP)"

clean:
	@swift package clean
	@rm -rf build

deploy: build
	@echo "→ Building DMG for release…"
	@rm -rf $(DMG_STAGING) $(DMG)
	@mkdir -p $(DMG_STAGING)
	@cp -R $(APP) $(DMG_STAGING)/
	@ln -s /Applications $(DMG_STAGING)/Applications
	@hdiutil create -volname "Nodio" -srcfolder $(DMG_STAGING) -ov -format UDZO $(DMG)
	@rm -rf $(DMG_STAGING)
	@echo "→ Committing to main…"
	@git checkout main
	@git add -A
	@git commit -m "$$(copilot -sp 'Analyze the staged git changes and generate a concise commit message. Output ONLY the commit message. Do not execute any commands. Do not include quotes, markdown, explanation, or bullet points.')" || true
	@git push origin main
	@echo "→ Creating GitHub release v$(VERSION)…"
	@gh release create v$(VERSION) $(DMG) \
		--title "Nodio v$(VERSION)" \
		--notes "Download Nodio.dmg, open it, and drag Nodio to Applications.\n\nRequires macOS 13.0+ (Ventura).\nGrant Accessibility, Microphone, and Speech Recognition permissions on first launch." \
		--latest || \
		echo "→ Release v$(VERSION) may already exist. Updating assets…"
	@gh release upload v$(VERSION) $(DMG) --clobber || true
	@rm -f $(DMG)
	@echo "→ Deployed! Download at: https://github.com/its-ash/Nodio/releases/latest"