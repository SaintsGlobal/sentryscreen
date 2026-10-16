#!/bin/bash
# Canonical source inventory for scripts installed by the package builder.

# Requirement Receipt: build-pkg.sh installs five persistent support scripts
# and four Installer scripts. The source-egress gate must inspect that exact set
# so a newly installed script cannot bypass review. No installed shell script
# has network capability.
# These arrays are consumed by scripts that source this file.
# shellcheck disable=SC2034
SENTRY_SUPPORT_SCRIPT_SOURCES=(
  packaging/watchdog.sh
  packaging/agent-launch.sh
  packaging/uninstall.sh
  packaging/reset-pin.sh
  packaging/pkg-scripts/json-tool.sh
)

SENTRY_INSTALLER_SCRIPT_SOURCES=(
  packaging/pkg-scripts/preinstall
  packaging/pkg-scripts/postinstall
  packaging/pkg-scripts/configure-install.sh
  packaging/pkg-scripts/json-tool.sh
)
