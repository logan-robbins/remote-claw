variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "network_security_group_id" {
  type = string
}

variable "vm_name" {
  type = string
}

variable "vm_size" {
  type = string
}

variable "admin_username" {
  type = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "source_image_id" {
  description = "Gallery image version URN. Fleet VMs deploy from the baked claw-desktop-gpu image."
  type        = string
}

variable "image_plan" {
  description = "Marketplace purchase plan inherited from the gallery image's purchase_plan. Required when the source image was baked from a marketplace base; null otherwise."
  type = object({
    name      = string
    publisher = string
    product   = string
  })
  default = null
}

variable "data_disk_size_gb" {
  type = number
}

variable "data_disk_sku" {
  type = string
}

variable "cloud_init_template_path" {
  type = string
}

variable "openclaw_model" {
  type = string
}

variable "telegram_bot_token" {
  type      = string
  sensitive = true
}

variable "telegram_user_id" {
  type    = string
  default = ""
}

variable "xai_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "openai_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "anthropic_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "moonshot_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "deepseek_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "brightdata_api_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "tailscale_authkey" {
  type      = string
  sensitive = true
  default   = ""
}

variable "relay_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "admin_ssh_public_key" {
  type        = string
  description = "SSH public key for key-based authentication. If set, added alongside password auth."
  default     = ""
}

variable "enable_trusted_launch" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
