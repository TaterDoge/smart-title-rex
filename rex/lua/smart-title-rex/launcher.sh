#!/bin/sh

export SMART_TITLE_PARENT_PID=$PPID
export SMART_TITLE_LAUNCHER_PID=$$
daemon=$1

# Rex server's PATH usually holds no `rex`; the running server is itself the binary.
rex_bin=$(command -v rex 2>/dev/null)
if [ -z "$rex_bin" ]; then
	if [ -e "/proc/$SMART_TITLE_PARENT_PID/exe" ]; then
		rex_bin=$(readlink "/proc/$SMART_TITLE_PARENT_PID/exe" 2>/dev/null)
	else
		rex_bin=$(ps -p "$SMART_TITLE_PARENT_PID" -o comm= 2>/dev/null)
	fi
fi
if [ ! -x "$rex_bin" ]; then
	echo "smart-title-rex: cannot find the rex executable" >&2
	exit 1
fi

child=

stop() {
	if [ -n "$child" ]; then
		kill "$child" 2>/dev/null
	fi
	exit 0
}

trap stop TERM INT

# Rex loads config before its socket or restored sessions are ready.
while true; do
	"$rex_bin" --autostart=false do "$daemon" --all &
	child=$!
	wait "$child"
	status=$?
	child=

	if [ "$status" -eq 0 ]; then
		exit 0
	fi
	if ! kill -0 "$SMART_TITLE_PARENT_PID" 2>/dev/null; then
		exit 0
	fi

	sleep 1 &
	child=$!
	wait "$child"
	child=
done