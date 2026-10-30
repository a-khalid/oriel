.PHONY: app release run test lint-strings smoke clean

app:
	scripts/build-app.sh debug

release:
	scripts/build-app.sh release

run: app
	open build/Nafitha.app

test:
	swift test

lint-strings:
	scripts/check-localizations.sh

clean:
	rm -rf .build build

smoke:
	scripts/smoke.sh $(ISO)
