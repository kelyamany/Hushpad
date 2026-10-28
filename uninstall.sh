#!/bin/zsh
# Removes Hushpad (and LocalScribe, its name before 1.1) from this Mac: the app, its settings, permissions, caches,
# API keys, speech models and build files. Your meetings, and the library key that encrypted meetings need, stay.
#
#   ./uninstall.sh            this Mac
#   ./uninstall.sh --iphone   …and the connected iPhone (and its Watch); asks first, since that deletes meetings kept only there
exec "${0:A:h}/install.sh" --uninstall "$@"
