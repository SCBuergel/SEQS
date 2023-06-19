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
2. Open dom0 terminal and type the following one-liner (this is a common hack to copy files from an app VM into dom0):
```
qvm-run -p personal 'cat /home/user/SEQS/SetupQubes.sh' >> s.sh && chmod +x s.sh && ./s.sh
```
3. Some software packages require you to reboot the app VM once to actually work.

The script will download the individual install scripts into dom0 and from there to newly created template VMs. The template VMs are then used to set up app VMs for proper isolation.

Control the actual software packages that are installed at the bottom of the `SetupQubes.sh` file.

### I want to automate installation of [XYZ]
In order to add additional software packages, create corresponding install scripts to the respective folder. If needed (e.g. in case of AppImage donwloads) add menu files so that the program can be launched from the Qubes menu. 

## Helpers
### cleanup.sh
The following script cleans up VMs while debugging and setting up installers:
```
./deleteVMs keepass telegram wallets
```

### Firewall setup between app VMs

For some use cases it is useful to allow for selective connections between individual app VMs. One example is the RPCh server running within the wallets app VM and another browser and browser wallet app VM. In order to do that find the two respective IPs and set the iptables in the sys-firewall qube

On both RPCh and brave app VM do
```
hostname -I
```

within the sys-firewall do
```
iptables -I FORWARD 2 -s IP_BRAVE -d IP_RPCH -j ACCEPT
```

e.g.
```
iptables -I FORWARD 2 -s 10.137.0.25 -d 10.137.0.51 -j ACCEPT
```
