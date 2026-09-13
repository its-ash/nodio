.PHONY: run build deploy clean

APP = build/Nodio.app
BIN = .build/debug/VoxType

run: build
	@echo "→ Launching Nodio…"
	@open "$(APP)"

build:
	@echo "→ Building Nodio…"
	@swift build
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp .build/debug/VoxType "$(APP)/Contents/MacOS/Nodio"
	@cp VoxType/Info.plist "$(APP)/Contents/Info.plist"
	@codesign --force --deep --sign - --identifier com.nodio.app \
		--entitlements VoxType/Nodio.entitlements "$(APP)"
	@echo "→ Built $(APP)"

clean:
	@swift package clean
	@rm -rf build

deploy: build
	@git checkout main
	@git add -A
	@git commit -m "$$(copilot -sp 'Analyze the staged git changes and generate a concise commit message. Output ONLY the commit message. Do not execute any commands. Do not include quotes, markdown, explanation, or bullet points.')" || true
	@git push origin main