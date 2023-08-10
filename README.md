# Seb's QubesOS Scripts

## Installing QubesOS
1. Start with an empty 8GB USB stick
2. Download the latest [Qubes OS ISO image](https://www.qubes-os.org/downloads/)
3. On the first install selection menu (in terminal) right after selecting the boot media, select installation with latest kernel. I have a lot of issues with [graphics lagging](https://forum.qubes-os.org/t/extremely-slow-performance-on-qubes-4-1/10060/19) and [wifi adapter not being found](https://forum.qubes-os.org/t/how-to-connect-to-wi-fi/11965/13).
4. I create partitions and mount points as follows:
    1. 1 GB `/boot/efi`
    2. 1 GB `/boot`
    3. 32 GB `swap` (encrypted)
    4. whatever is left `/` (encrypted)
5. For convenience I like window tiling to arrange windows neatly: Qubes menu -> System Tools -> Window Manager -> Keyboard -> scroll down to the Tile settings which I set as follows:

![Screenshot of Qubes Window Manager Keyboard settings](https://github.com/SCBuergel/SEQS/blob/main/WindowManagerTile.png?raw=true)

6. After connecting to wifi, the system update icon should appear in the tray on the top right, run all updates and reboot

## Install software
I set up a template VM for every software that I want to use and then create an app VM that I actually run for using the software. To keep the Qubes menu and Qubes manager clean, all my template VMs are prefixed `ZZ-[AppName]` and my app VMs are prefixed `AA-[AppName]`. This repository contains a range of scripts that set up template VMs and app VMs for several software packages. In order to create them, you are copying files from an app VM to your dom0.

**WARNING: Please note that this is a potential security threat as it exposes your dom0 environment to running a bunch of scripts which I do not guarantee to be safe, so please check all files by yourself and only proceed if you understood everything and considered all actions to be safe!**

In order to set up everything in an automated fashion:
1. Download this repo into the home directory of your `personal` app VM
2. Open dom0 terminal and type the following one-liner (this is a [common hack to copy files from an app VM into dom0](https://www.qubes-os.org/doc/how-to-copy-from-dom0/#copying-to-dom0)):
```
qvm-run -p personal 'cat /home/user/SEQS/setup-qubes.sh' > s.sh && chmod +x s.sh && ./s.sh
```
3. Some software packages require you to reboot the app VM once to actually work.

The script will download the individual install scripts into dom0 and from there to newly created template VMs. The template VMs are then used to set up app VMs for proper isolation.

Control the actual software packages that are installed at the bottom of the `setup-qubes.sh` file.

### I want to automate installation of [XYZ]
In order to add additional software packages, create corresponding install scripts to the respective folder. If needed (e.g. in case of AppImage donwloads) add menu files so that the program can be launched from the Qubes menu. 

## Helpers
### delete-vms.sh
The following script cleans up VMs while debugging and setting up installers:
```
./delete-vms.sh keepass telegram wallets
```

### Firewall setup between app VMs (TODO: script this)
For some use cases it is useful to allow for selective connections between individual app VMs. One example is the [RPCh server](https://access.rpch.net/) running within the `A-docker` app VM that shoud be accessible from an `A-wallets` app VM. In order to do enable that, find the two respective IPs and set the iptables in the net VM. Since the default sys-firewall qube does not persist it's `/rw` folder, the following is required to persist the settings between system reboots (as suggest [on the Qubes Forum](https://forum.qubes-os.org/t/help-sys-firewall-has-no-persistence-rc-local-gets-wiped-on-reboot/19184/4)):
1. in dom0 find the IP addresses of both app VMs:
```
qvm-ls -n | grep -E 'A-wallets|A-docker'
```
```
hostname -I
```
2. clone `debian-11-dvm`, rename it as `app-sys-firewall`
3. clone `sys-firewall`, rename it as `sys-firewall-lab`
4. change template of `sys-firewall-lab` from `debian-11-dvm` to `app-sys-firewall`
5. configure changes on `app-sys-firewall` by opening a terminal in `app-sys-firewall`
```
echo "iptables -I FORWARD 2 -s IP_WALLETS -d IP_DOCKER -j ACCEPT" | sudo tee -a /rw/config/qubes-firewall-user-script
```
e.g.
```
echo "iptables -I FORWARD 2 -s 10.137.0.55 -d 10.137.0.51 -j ACCEPT" | sudo tee -a /rw/config/qubes-firewall-user-script
```
6. start `sys-firewall-lab`
7. configure both RPCh app VM and wallet app VM to use `sys-firewall-lab` as their net cube. You can do that from the `dom0` terminal via:
```
qvm-prefs A-docker netvm sys-firewall-lab
qvm-prefs A-wallets netvm sys-firewall-lab
```
9. Now the wallet qube should be able to use the RPCh server on the other app VM. Test e.g. by calling the RPCh app VM via command line:
```
curl 10.137.0.51:8080/?exit-provider=https://primary.gnosis-chain.rpc.hoprtech.net -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

If you re-install either of the two qubes, remember to update the entry in `/rw/config/qubes-firewall-user-script` with the respective new IPs.

### vim mappings (TODO: script this)
I like to move screen lines in vim instead of wrapped physical lines so I use the following `~/.vimrc` file:
```
noremap <up> gk
noremap <down> gj
inoremap <up> <C-o>gk
inoremap <down> <C-o>gj
```
