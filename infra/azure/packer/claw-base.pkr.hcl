packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}

source "azure-arm" "claw-base" {
  subscription_id    = var.subscription_id
  use_azure_cli_auth = true
  location           = var.location
  vm_size            = var.vm_size

  os_type         = "Linux"
  image_publisher = "Canonical"
  image_offer     = "ubuntu-24_04-lts"
  image_sku       = "server"

  shared_image_gallery_destination {
    gallery_name    = var.gallery_name
    image_name      = var.image_name
    image_version   = var.image_version
    resource_group  = var.resource_group
    replication_regions = [var.location]
  }

  # Trusted launch (matches claw-vm module settings)
  security_type       = "TrustedLaunch"
  secure_boot_enabled = true
  vtpm_enabled        = true

  # No managed_image_name — publish directly to gallery with trusted launch
}

build {
  sources = ["source.azure-arm.claw-base"]

  # ---- Install scripts (numbered for ordering) ----
  provisioner "shell" {
    scripts = [
      "scripts/01-system-packages.sh",
      "scripts/02-desktop-config.sh",
      "scripts/03-nodejs-openclaw.sh",
      "scripts/04-chrome.sh",
      "scripts/05-claude-code.sh",
      "scripts/06-tailscale.sh",
      "scripts/07-system-setup.sh",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo {{ .Path }}"
  }

  # ---- Stage vm-runtime boot files onto the image ----
  provisioner "shell" {
    inline = ["sudo mkdir -p /opt/claw/defaults /opt/claw/updates"]
  }

  provisioner "file" {
    source      = "../../../vm-runtime/lifecycle/boot.sh"
    destination = "/tmp/boot.sh"
  }
  provisioner "file" {
    source      = "../../../vm-runtime/lifecycle/run-updates.sh"
    destination = "/tmp/run-updates.sh"
  }
  provisioner "file" {
    source      = "../../../vm-runtime/lifecycle/start-claude.sh"
    destination = "/tmp/start-claude.sh"
  }
  provisioner "file" {
    source      = "../../../vm-runtime/lifecycle/verify.sh"
    destination = "/tmp/verify.sh"
  }
  provisioner "file" {
    source      = "../../../vm-runtime/defaults/"
    destination = "/tmp/defaults/"
  }
  provisioner "file" {
    source      = "../../../vm-runtime/updates/"
    destination = "/tmp/updates/"
  }

  # Move staged files into place (file provisioner runs as packer user, not root)
  provisioner "shell" {
    inline = [
      "sudo cp /tmp/boot.sh /opt/claw/boot.sh",
      "sudo cp /tmp/run-updates.sh /opt/claw/run-updates.sh",
      "sudo cp /tmp/start-claude.sh /opt/claw/start-claude.sh",
      "sudo cp /tmp/verify.sh /opt/claw/verify.sh",
      "sudo chmod +x /opt/claw/boot.sh /opt/claw/run-updates.sh /opt/claw/start-claude.sh /opt/claw/verify.sh",
      "sudo cp -a /tmp/defaults/. /opt/claw/defaults/",
      "sudo cp -a /tmp/updates/. /opt/claw/updates/",
      "sudo chmod +x /opt/claw/updates/*.sh 2>/dev/null || true",
      "rm -rf /tmp/boot.sh /tmp/run-updates.sh /tmp/start-claude.sh /tmp/verify.sh /tmp/defaults /tmp/updates",
    ]
  }

  # ---- Cleanup and generalize ----
  provisioner "shell" {
    script          = "scripts/99-cleanup.sh"
    execute_command = "chmod +x {{ .Path }}; sudo {{ .Path }}"
  }
}
