.PHONY: run build deploy clean release

APP = build/Nodio.app
BIN = .build/debug/VoxType
DMG = build/Nodio.dmg
DMG_STAGING = build/dmg-staging
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" VoxType/Info.plist)
COMMIT_API = http://127.0.0.1:9694/v1
COMMIT_MODEL = router/auto
COMMIT_PROMPT = Analyze the staged git changes and generate a concise commit message. Output ONLY the commit message on one line. No quotes, markdown, explanation, or bullet points.

run: build
	@echo "→ Launching Nodio…"
	@open "$(APP)"

build:
	@echo "→ Building Nodio…"
	@swift build
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Frameworks"
	@cp .build/debug/VoxType "$(APP)/Contents/MacOS/Nodio"
	@rm -rf "$(APP)/Contents/Frameworks/whisper.framework"
	@ditto .build/debug/whisper.framework "$(APP)/Contents/Frameworks/whisper.framework"
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
	@DIFF="$$(git diff --cached --stat; echo; git diff --cached | head -c 60000)"; \
	MSG="$$(jq -n --arg d "$$DIFF" --arg m "$(COMMIT_MODEL)" --arg p "$(COMMIT_PROMPT)" \
		'{model:$$m,temperature:0.2,messages:[{role:"system",content:$$p},{role:"user",content:$$d}]}' \
		| curl -sf -m 90 "$(COMMIT_API)/chat/completions" -H 'Content-Type: application/json' -d @- \
		| jq -r '.choices[0].message.content // empty' \
		| sed -e '/^```/d' -e '/^[[:space:]]*$$/d' -e 's/^["'\'']//' -e 's/["'\'']$$//' | head -1)"; \
	git commit -m "$${MSG:-Release v$(VERSION)}" || true
	@git push origin main
	@echo "→ Creating GitHub release v$(VERSION)…"
	@gh release create v$(VERSION) $(DMG) \
		--title "Nodio v$(VERSION)" \
		--notes "Download Nodio.dmg, open it, and drag Nodio to Applications.\n\nRequires macOS 13.3+ (Ventura).\nGrant Accessibility and Microphone permissions on first launch. The Whisper model (~574 MB) downloads once on first launch." \
		--latest || \
		echo "→ Release v$(VERSION) may already exist. Updating assets…"
	@gh release upload v$(VERSION) $(DMG) --clobber || true
	@rm -f $(DMG)
	@echo "→ Deployed! Download at: https://github.com/its-ash/Nodio/releases/latest"