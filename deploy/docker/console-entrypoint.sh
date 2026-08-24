#!/bin/sh
set -eu

exec /usr/local/bin/blaktail-config run-console -- "$@"
