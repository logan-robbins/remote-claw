# ---------- Look up shared infrastructure ----------

data "azurerm_resource_group" "this" {
  name = local.azure.resource_group_name
}

data "azurerm_virtual_network" "this" {
  name                = local.azure.virtual_network_name
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_subnet" "this" {
  name                 = local.azure.subnet_name
  virtual_network_name = data.azurerm_virtual_network.this.name
  resource_group_name  = data.azurerm_resource_group.this.name
}

data "azurerm_network_security_group" "this" {
  name                = local.azure.network_security_group_name
  resource_group_name = data.azurerm_resource_group.this.name
}

# ---------- Per-claw resources ----------

resource "random_password" "vm_password" {
  for_each = local.claws_with_secrets

  length           = 20
  special          = true
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!#%*+-_="
}

module "claw_vm" {
  source   = "../modules/claw-vm"
  for_each = local.claws_with_secrets

  location                  = data.azurerm_resource_group.this.location
  resource_group_name       = data.azurerm_resource_group.this.name
  subnet_id                 = data.azurerm_subnet.this.id
  network_security_group_id = data.azurerm_network_security_group.this.id
  vm_name                   = each.key
  vm_size                   = each.value.vm_size
  admin_username            = each.value.admin_username
  admin_password            = random_password.vm_password[each.key].result
  source_image_id = format(
    "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/galleries/%s/images/%s/versions/%s",
    data.azurerm_client_config.current.subscription_id,
    data.azurerm_resource_group.this.name,
    local.azure.gallery_name,
    local.azure.image_definition_name,
    each.value.image_version,
  )
  data_disk_size_gb        = each.value.data_disk_size_gb
  data_disk_sku            = each.value.data_disk_sku
  cloud_init_template_path = local.cloud_init_template
  openclaw_model           = each.value.model
  telegram_bot_token       = each.value.secrets.telegram_bot_token
  telegram_user_id         = try(each.value.telegram_user_id, "")
  xai_api_key              = each.value.secrets.xai_api_key
  openai_api_key           = each.value.secrets.openai_api_key
  anthropic_api_key        = each.value.secrets.anthropic_api_key
  moonshot_api_key         = each.value.secrets.moonshot_api_key
  deepseek_api_key         = each.value.secrets.deepseek_api_key
  brightdata_api_token     = each.value.secrets.brightdata_api_token
  tailscale_authkey        = each.value.secrets.tailscale_authkey
  admin_ssh_public_key     = var.admin_ssh_public_key
  enable_trusted_launch    = try(each.value.enable_trusted_launch, true)
  tags                     = merge(local.shared_tags, try(each.value.tags, {}), { claw = each.key })
}
