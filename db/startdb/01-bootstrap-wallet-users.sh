#!/usr/bin/env bash
# Called by the official Oracle image AFTER the database is up, on every start.
# Launch the existing bootstrap in a child shell: do not leak its shell options
# into the Oracle image entrypoint when a non-executable .sh is sourced.
bash /opt/wallet-bootstrap/create-users.sh || exit 1
