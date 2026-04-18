packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}

# claw-desktop-gpu: IMMUTABLE BASELINE image.
#
# Bakes ONLY the desktop layer on top of AMD's pre-installed V710 marketplace
# image: XFCE + LightDM + dummy Xorg + xrdp + Sunshine + base tooling.
# The application layer (Node, OpenClaw, Chrome, Claude Code, Tailscale,
# agent services, vm-runtime payload) is NOT baked — it installs at deploy
# time via cloud-init so we can iterate on it without re-baking.
#
# Bake this once per OS/driver/protocol upgrade. Fleet redeploys reuse the
# same image artifact.

source "azure-arm" "claw-desktop" {
  subscription_id    = var.subscription_id
  use_azure_cli_auth = true
  location           = var.location
  vm_size            = var.vm_size

  os_type = "Linux"

  # AMD V710 marketplace image (Ubuntu + amdgpu pre-installed).
  image_publisher = "amdinc1746636494855"
  image_offer     = "nvv5_v710_linux_rocm_image"
  image_sku       = "planid125"
  image_version   = "1.0.2"

  plan_info {
    plan_name      = "planid125"
    plan_product   = "nvv5_v710_linux_rocm_image"
    plan_publisher = "amdinc1746636494855"
  }

  shared_image_gallery_destination {
    gallery_name        = var.gallery_name
    image_name          = "claw-desktop-gpu"
    image_version       = var.image_version
    resource_group      = var.resource_group
    replication_regions = [var.location]
  }

  # AMD marketplace image does not support Trusted Launch.
}

build {
  sources = ["source.azure-arm.claw-desktop"]

  # Desktop layer ONLY: XFCE + LightDM + dummy Xorg + xrdp + Sunshine.
  # Application layer is installed at deploy time via cloud-init.
  provisioner "shell" {
    scripts = [
      "../../../../vm-runtime/install/desktop/01-system-packages.sh",
      "../../../../vm-runtime/install/desktop/03-display-config.sh",
      "../../../../vm-runtime/install/desktop/04-xrdp.sh",
      "../../../../vm-runtime/install/desktop/05-sunshine.sh",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo {{ .Path }}"
  }

  # Generalize the image so Azure can clone it cleanly. Inline (no separate
  # 99-cleanup.sh anymore — that script also did per-VM cleanup that's
  # harmful on a live deploy).
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo rm -rf /tmp/* 2>/dev/null || true",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo find /var/log -type f -exec truncate -s 0 {} \\;",
      "rm -f $HOME/.bash_history",
      "sudo /usr/sbin/waagent -force -deprovision+user",
      "sync",
    ]
    execute_command = "{{ .Path }}"
    inline_shebang  = "/bin/bash -e"
  }
}
