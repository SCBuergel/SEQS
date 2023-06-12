## Installing QubesOS
1. Start with an empty 8GB USB stick
2. Download the latest [Qubes OS ISO image](https://www.qubes-os.org/downloads/)
3. On the first install selection menu (in terminal) right after selecting the boot media, select installation with latest kernel. I have a lot of issues with [graphics lagging](https://forum.qubes-os.org/t/extremely-slow-performance-on-qubes-4-1/10060/19) and [wifi adapter not being found](https://forum.qubes-os.org/t/how-to-connect-to-wi-fi/11965/13).
4. I create partitions and mount points as follows:
4.1 1 GB `/boot/efi`
4.2 1 GB `/boot`
4.3 32 GB `swap` (encrypted)
4.4 whatever is left `/` (encrypted)
5. For convenience I like window tiling to arrange windows neatly: Qubes menu -> System Tools -> Window Manager -> Keyboard -> scroll down to the Tile settings which I set as follows: 
6. After connecting to wifi, the system update icon should appear in the tray on the top right, run all updates and reboot

## Install software
I set up a template VM for every software that I want to use and then create an app VM that I actually run for using the software. To keep the Qubes menu and Qubes manager clean, all my template VMs are prefixed `ZZ-[AppName]` and my app VMs are prefixed `AA-[AppName]`.

In order to set up everything in an automated fashion:
1. Download this repo into the home directory of your `personal` app VM
2. Open dom0 terminal and type the following one-liner:
```
qvm-run --pass-io personal 'cat /home/user/SEQS/SetupQubes.sh' >> SetupQubes.sh && chmod +x SetupQubes.sh && ./SetupQubes.sh
```

## Helpers
### fetch-from-vm
The following script can be used from within dom0 to copy trusted files from a VM to dom0. It can be stored in dom0 in `/home/user/.local/bin/fetch-from-vm` and it can be used via e.g. `fetch-from-vm personal /home/user/SetupQubes.sh`

```
if [ $# -ne 2 ]; then
echo "Expect two parameters: fetch-from-vm source_vm file"
exit 1
fi
FILE=$(basename "$2")
rm $FILE 2>>/dev/null
qvm-run --pass-io $1 cat $2 >> $FILE
chmod +x $FILE
```
### cleanup.sh
The following script cleans up VMs while debugging and setting up installers:
```
function deleteVMs () {
        for app in "$@"; do
                qvm-shutdown ZZ-$app 2>>/dev/null
                qvm-shutdown AA-$app 2>>/dev/null
                echo "waiting for qubes to shut down..."
                sleep 2
                qvm-remove AA-$app -f
                qvm-remove ZZ-$app -f
        done
}

cd ~
rm SetupQubes.sh 2>>/dev/null
rm ./.local/bin/fetch-from-vm 2>>/dev/null

deleteVMs keepass
```
