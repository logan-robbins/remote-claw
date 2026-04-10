# remote-claw

A single-VM Azure deployment of Ubuntu 24.04 with a **persistent xfce4 desktop on `:0`, exposed over VNC**, so long-running workloads keep running whether or not anyone is connected. Based on the shape of Microsoft's tutorial https://learn.microsoft.com/en-us/azure/virtual-machines/linux/use-remote-desktop (with `x11vnc` substituted for `xrdp` so the viewer attaches to the same `:0` session the workload runs in).

## What this is

One shell script, one cloud-init file. `az vm create` from stock Ubuntu 24.04, cloud-init installs `xfce4 + lightdm + x11vnc`. `lightdm` auto-logs in `azureuser` into an xfce session on `:0` at boot, and `x11vnc` attaches to that `:0` display so any VNC viewer sees exactly what's on the long-running session. Connect with any VNC client (macOS Finder has one built in).

**Always-on behavior:** the `:0` session exists from the moment the VM boots, independent of whether anyone is viewing. Disconnect your VNC client, the session keeps running. Reconnect later, you see the same state.

## Reproducible from any Azure account

Everything in this repo is plain text. There are no pre-baked images, no gallery dependencies, no account-specific identifiers committed anywhere. Clone, `az login` to your own account, run `./deploy.sh`. Works in any subscription, any tenant, any region. The canonical source of truth is `cloud-init.yaml`.

## Security posture

**Wide open, on purpose.** The NSG allows all protocols and all ports from all sources. `ufw` is explicitly disabled on the host. VNC listens on `0.0.0.0:5900` protected only by a random 16-character password generated at first boot. This is a dev/experimentation VM, not a production host. Do not run anything sensitive on it.

## Prerequisites

- Azure CLI logged in (`az login`)
- At least one SSH public key in `~/.ssh/*.pub`. `deploy.sh` auto-detects it; if you have multiple, it will prompt you to pick one. Override with `SSH_KEY_FILE=path/to/key.pub ./deploy.sh` to skip the prompt.
- A VNC client. macOS has one built in (Finder > Go > Connect to Server > `vnc://<ip>:5900`). Linux: Remmina or `vncviewer`. Windows: RealVNC Viewer, TightVNC, or similar.

## Deploy

    ./deploy.sh

Environment overrides (all optional):

    RG=my-rg LOCATION=westus2 VM_NAME=my-desktop VM_SIZE=Standard_D4s_v5 ./deploy.sh

## Connect

1. Wait for cloud-init to finish (~5-10 min on first boot):

       ssh azureuser@<ip> 'sudo cloud-init status --wait'

2. Retrieve the randomly-generated VNC password:

       ssh azureuser@<ip> 'cat ~/vnc-password.txt'

3. Open your VNC client and connect to `vnc://<ip>:5900`. Paste the password from step 2. You are now viewing the `:0` session.

## Daily stop / start (keep disk, save money)

The VM is intended to be stopped when not in use. Always use **deallocate** (not stop) so compute billing stops. The OS disk and public IP persist across cycles — your installed software, files, and IP address are preserved.

    az vm deallocate -g rg-linux-desktop -n linux-desktop   # end of session
    az vm start      -g rg-linux-desktop -n linux-desktop   # start of session

## Destroy permanently

    az group delete --name rg-linux-desktop --yes --no-wait

## Verification

    ssh azureuser@<ip> 'sudo ss -tlnp | grep :5900'

Expect `x11vnc` listening on `0.0.0.0:5900`.

    ssh azureuser@<ip> 'systemctl is-active lightdm x11vnc'

Expect `active` twice.

    ssh azureuser@<ip> 'pgrep -af xfce4-session'

Expect at least one running `xfce4-session` process owned by `azureuser`, confirming the lightdm auto-login landed.
