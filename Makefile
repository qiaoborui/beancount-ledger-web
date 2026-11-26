.PHONY: install-dev

# Build the iOS app and install it on the connected iPhone (scripts/dev-install-ios.sh).
#   make install-dev              this checkout, uncommitted edits included
#   make install-dev PR=748       a pull request, built in a separate worktree
#   make install-dev REF=origin/main
# Optional: DEVICE=<name|UDID>, WAIT=<seconds to wait for a locked phone>, LAUNCH=0.
install-dev:
	@bash scripts/dev-install-ios.sh $(if $(PR),$(PR),$(REF))
