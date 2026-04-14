locals {
  rendered_cloud_init = templatefile(var.cloud_init_template_path, {
    OPENCLAW_MODEL       = var.openclaw_model
    XAI_API_KEY          = var.xai_api_key
    OPENAI_API_KEY       = var.openai_api_key
    ANTHROPIC_API_KEY    = var.anthropic_api_key
    MOONSHOT_API_KEY     = var.moonshot_api_key
    DEEPSEEK_API_KEY     = var.deepseek_api_key
    BRIGHTDATA_API_TOKEN = var.brightdata_api_token
    TELEGRAM_BOT_TOKEN   = var.telegram_bot_token
    TELEGRAM_USER_ID     = var.telegram_user_id
    VM_PASSWORD          = var.admin_password
    TAILSCALE_AUTHKEY    = var.tailscale_authkey
  })
}

resource "azurerm_public_ip" "this" {
  name                = "${var.vm_name}-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "this" {
  name                = "${var.vm_name}-nic"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = var.network_security_group_id
}

resource "azurerm_managed_disk" "data" {
  name                 = "${var.vm_name}-data"
  resource_group_name  = var.resource_group_name
  location             = var.location
  storage_account_type = var.data_disk_sku
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = var.vm_name
  computer_name                   = var.vm_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.this.id]
  custom_data                     = base64encode(local.rendered_cloud_init)
  source_image_id                 = var.source_image_id
  secure_boot_enabled             = var.enable_trusted_launch
  vtpm_enabled                    = var.enable_trusted_launch
  tags                            = var.tags

  dynamic "admin_ssh_key" {
    for_each = var.admin_ssh_public_key != "" ? [1] : []
    content {
      username   = var.admin_username
      public_key = var.admin_ssh_public_key
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "this" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  lun                = 0
  caching            = "ReadWrite"
}
