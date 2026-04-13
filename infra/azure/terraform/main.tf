module "shared_infra" {
  source = "./modules/shared-infra"

  location                    = local.azure.location
  resource_group_name         = local.azure.resource_group_name
  virtual_network_name        = local.azure.virtual_network_name
  subnet_name                 = local.azure.subnet_name
  network_security_group_name = local.azure.network_security_group_name
  address_space               = local.azure.address_space
  subnet_prefixes             = local.azure.subnet_prefixes
  tags                        = local.shared_tags
}

module "image_gallery" {
  source = "./modules/image-gallery"

  location               = module.shared_infra.location
  resource_group_name    = module.shared_infra.resource_group_name
  gallery_name           = local.azure.gallery_name
  image_definition_name  = local.azure.image_definition_name
  image_identifier       = local.image_identifier
  hyper_v_generation     = try(local.azure.hyper_v_generation, "V2")
  trusted_launch_enabled = try(local.azure.trusted_launch_enabled, true)
  tags                   = local.shared_tags
}

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
  source   = "./modules/claw-vm"
  for_each = local.claws_with_secrets

  location                  = module.shared_infra.location
  resource_group_name       = module.shared_infra.resource_group_name
  subnet_id                 = module.shared_infra.subnet_id
  network_security_group_id = module.shared_infra.network_security_group_id
  vm_name                   = each.key
  vm_size                   = each.value.vm_size
  admin_username            = each.value.admin_username
  admin_password            = random_password.vm_password[each.key].result
  source_image_id = format(
    "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/galleries/%s/images/%s/versions/%s",
    data.azurerm_client_config.current.subscription_id,
    module.shared_infra.resource_group_name,
    module.image_gallery.gallery_name,
    module.image_gallery.image_definition_name,
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
  brightdata_api_token     = each.value.secrets.brightdata_api_token
  tailscale_authkey        = each.value.secrets.tailscale_authkey
  enable_trusted_launch    = try(each.value.enable_trusted_launch, true)
  tags                     = merge(local.shared_tags, try(each.value.tags, {}), { claw = each.key })
}
