PREFIX_APP_VM="A-"
PREFIX_TEMPLATE_VM="Z-"

for app in "$@"; do
	echo "deleting $app..."
	qvm-kill $PREFIX_TEMPLATE_VM$app 2>>/dev/null
	qvm-kill $PREFIX_APP_VM$app 2>>/dev/null
	echo "waiting for qubes to shut down..."
	sleep 3
	qvm-remove $PREFIX_APP_VM$app -f
	qvm-remove $PREFIX_TEMPLATE_VM$app -f
done
