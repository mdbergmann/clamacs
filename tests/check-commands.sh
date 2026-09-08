#!/bin/sh
# check-commands.sh -- every command in the table must be implemented.
#
# The command table is a promise made to two audiences at once: `M-x' offers
# every name in it for completion, and the editor's ARexx port accepts every
# name as `EVAL <name>'.  A name with no case in ck_doc_run_command() is
# therefore not a harmless stub -- it is a command the user can find, type
# and watch do nothing.
#
# This cannot be a C unit test: what it checks is the MUI layer, which does
# not compile on the host by design.  A grep is the honest tool.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TABLE="$ROOT/src/emacs/command.h"
IMPL="$ROOT/src/document.c"

missing=""
for sym in $(sed -n 's/^ *X(\([A-Z0-9_]*\),.*/\1/p' "$TABLE"); do
	grep -q "case CK_CMD_$sym:" "$IMPL" || missing="$missing $sym"
done

if [ -n "$missing" ]; then
	echo "FAIL  commands in the table with no implementation:"
	for sym in $missing; do echo "        CK_CMD_$sym"; done
	echo "      Implement them in ck_doc_run_command(), or take them out of"
	echo "      CK_COMMAND_LIST -- M-x and the ARexx port both offer whatever"
	echo "      is in that table."
	exit 1
fi

echo "  ok  every command in the table is implemented"
exit 0
