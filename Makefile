.PHONY: app release dmg run test lint-strings smoke clean icon snapshots

app:
	scripts/build-app.sh debug

release:
	scripts/build-app.sh release

dmg: release
	scripts/make-dmg.sh

run: app
	open build/Oriel.app

test:
	swift test

lint-strings:
	scripts/check-localizations.sh

clean:
	rm -rf .build build

smoke:
	scripts/smoke.sh $(ISO)

icon:
	scripts/make-icon.sh

snapshots: app
	ORIEL_SNAPSHOTS=build/snapshots/en build/Oriel.app/Contents/MacOS/Oriel -AppleLanguages "(en)"
	ORIEL_SNAPSHOTS=build/snapshots/ar build/Oriel.app/Contents/MacOS/Oriel -AppleLanguages "(ar)" -AppleTextDirection YES
