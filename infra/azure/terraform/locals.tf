locals {
  fleet_manifest      = yamldecode(file("${path.root}/${var.fleet_manifest_path}"))
  azure               = local.fleet_manifest.azure
  defaults            = local.fleet_manifest.defaults
  cloud_init_template = "${path.root}/../../../vm-runtime/cloud-init/image.yaml"
  image_identifier    = local.azure.image_identifier
  shared_tags         = merge(try(local.azure.tags, {}), var.resource_tags)
  empty_secret_template = {
    telegram_bot_token   = ""
    xai_api_key          = ""
    openai_api_key       = ""
    anthropic_api_key    = ""
    brightdata_api_token = ""
    tailscale_authkey    = ""
  }

  claws = {
    for claw_name, claw_config in local.fleet_manifest.claws :
    claw_name => merge(local.defaults, claw_config, { name = claw_name })
  }

  claws_with_secrets = {
    for claw_name, claw_config in local.claws :
    claw_name => merge(claw_config, {
      secrets = merge(local.empty_secret_template, lookup(var.claw_secrets, claw_name, {}))
    })
  }

  missing_telegram_token_claws = [
    for claw_name, claw_config in local.claws_with_secrets :
    claw_name if trimspace(claw_config.secrets.telegram_bot_token) == ""
  ]

  missing_image_version_claws = [
    for claw_name, claw_config in local.claws_with_secrets :
    claw_name if trimspace(claw_config.image_version) == ""
  ]
}

check "claw_secrets_present" {
  assert {
    condition     = length(local.missing_telegram_token_claws) == 0
    error_message = "Missing telegram_bot_token entries in claw_secrets for: ${join(", ", local.missing_telegram_token_claws)}"
  }
}

check "image_versions_present" {
  assert {
    condition     = length(local.missing_image_version_claws) == 0
    error_message = "Missing image_version entries in fleet manifest for: ${join(", ", local.missing_image_version_claws)}"
  }
}
