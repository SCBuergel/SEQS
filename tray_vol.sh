qvm-run --pass-io GnosisVPN-app 'bash -c "sudo wg | awk '\''/transfer:/ {print \$2, \$3}'\''"'
