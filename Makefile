APP_NAME   = TimeTrackBar
CLI_NAME   = timetrack
BUILD_DIR  = .build/release
APP_BUNDLE = $(APP_NAME).app
BIN_DIR   ?= $(HOME)/.local/bin
AGENT_ID   = ca.senet.timetrackbar
AGENT_DIR  = $(HOME)/Library/LaunchAgents
AGENT      = $(AGENT_DIR)/$(AGENT_ID).plist

# macOS ties the Accessibility grant to the code signature. Signing with a stable
# identity means you approve TimeTrack once, not after every rebuild.
# Preference order: the dedicated self-signed cert, then any Apple Development
# certificate, then ad-hoc (-) as a last resort.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
	awk -F'"' '/TimeTrack Self-Signed/ { print $$2; found=1; exit } /Apple Development/ && !dev { dev=$$2 } END { if (!found && dev) print dev }')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY = -
endif

.PHONY: build bundle install install-cli install-app agent unagent uninstall run status clean signing-help dev

build:
	swift build -c release

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Sources/$(APP_NAME)/Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	codesign --force --deep --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE)
	@echo "Signed with identity: $(SIGN_IDENTITY)"

install-cli: build
	mkdir -p $(BIN_DIR)
	cp $(BUILD_DIR)/$(CLI_NAME) $(BIN_DIR)/$(CLI_NAME)
	codesign --force --sign "$(SIGN_IDENTITY)" $(BIN_DIR)/$(CLI_NAME)
	@echo "Installed $(BIN_DIR)/$(CLI_NAME)"
	@case ":$$PATH:" in *":$(BIN_DIR):"*) ;; \
	  *) echo ""; echo "NOTE: $(BIN_DIR) is not on your PATH."; \
	     echo "      Add this to ~/.zshrc:  export PATH=\"$(BIN_DIR):\$$PATH\"";; esac

install-app: bundle
	rm -rf /Applications/$(APP_BUNDLE)
	cp -r $(APP_BUNDLE) /Applications/
	@echo "Installed /Applications/$(APP_BUNDLE)"

install: install-cli install-app agent
	@echo ""
	@echo "Done. Next: grant Accessibility permission to TimeTrack."
	@echo "  System Settings > Privacy & Security > Accessibility > enable TimeTrackBar"
	@echo "Then check it with:  $(BIN_DIR)/$(CLI_NAME) status"

# Start the menu bar app at login and restart it if it ever dies.
agent:
	mkdir -p $(AGENT_DIR)
	sed 's|__APP_PATH__|/Applications/$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)|g; s|__LOG_DIR__|$(HOME)/.local/state/timetrack|g' \
	  scripts/$(AGENT_ID).plist.in > $(AGENT)
	mkdir -p $(HOME)/.local/state/timetrack
	-launchctl bootout gui/$$(id -u)/$(AGENT_ID) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "Login agent installed: $(AGENT)"

unagent:
	-launchctl bootout gui/$$(id -u)/$(AGENT_ID) 2>/dev/null
	rm -f $(AGENT)
	@echo "Login agent removed."

uninstall: unagent
	rm -rf /Applications/$(APP_BUNDLE)
	rm -f $(BIN_DIR)/$(CLI_NAME)
	@echo ""
	@echo "Binaries removed. Your data is still at ~/.local/share/timetrack/track.db"
	@echo "Delete it by hand if you want it gone."

# Rebuild, reinstall and restart in one step — use this while iterating.
dev:
	./scripts/dev-install.sh

run: bundle
	open $(APP_BUNDLE)

status: build
	$(BUILD_DIR)/$(CLI_NAME) status

signing-help:
	@echo "To create the stable signing identity (one time):"
	@echo "  1. Open Keychain Access"
	@echo "  2. Keychain Access > Certificate Assistant > Create a Certificate…"
	@echo "  3. Name: TimeTrack Self-Signed"
	@echo "     Identity Type: Self Signed Root"
	@echo "     Certificate Type: Code Signing"
	@echo "  4. Create, then re-run 'make install'"
	@echo ""
	@echo "Without it the build is ad-hoc signed and macOS may ask you to"
	@echo "re-approve Accessibility after each rebuild."

clean:
	rm -rf .build $(APP_BUNDLE)
