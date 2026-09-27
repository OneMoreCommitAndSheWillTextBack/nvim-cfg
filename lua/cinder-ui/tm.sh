#!/usr/bin/env bash
# private tmux server used to run/verify the cinder-ui demo
exec tmux -L cinder-ui-demo -f /dev/null "$@"
