################################################################################
# Generate a unique random string for resource name assignment and key pair
################################################################################
resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}


################################################################################
# Map default tags with values to be assigned to all tagged resources
################################################################################
locals {
  global_tags = {
    Owner                                                                                 = var.owner_tag
    ManagedBy                                                                             = "terraform"
    Vendor                                                                                = "Zscaler"
    "zs-edge-connector-cluster/${var.name_prefix}-cluster-${random_string.suffix.result}" = "shared"
  }
}



################################################################################
# 1. Create/reference all network infrastructure resource dependencies for all 
#    child modules (vpc, igw, nat gateway, subnets, route tables)
################################################################################
module "network" {
  source            = "github.com/locozoko/aws_lab_east/modules/terraform-zscc-network-aws"
  name_prefix       = var.name_prefix
  resource_tag      = random_string.suffix.result
  global_tags       = local.global_tags
  workloads_enabled = true
  az_count          = var.az_count
  vpc_cidr          = var.vpc_cidr
  public_subnets    = var.public_subnets
  workloads_subnets = var.workloads_subnets
  cc_subnets        = var.cc_subnets
  route53_subnets   = var.route53_subnets
  gwlb_enabled      = var.gwlb_enabled
  gwlb_endpoint_ids = module.gwlb_endpoint.gwlbe
  zpa_enabled       = var.zpa_enabled
}


################################################################################
# 2. Create Bastion Host for workload and CC SSH jump access
################################################################################
module "bastion" {
  source                    = "github.com/locozoko/aws_lab_east/modules/terraform-zscc-bastion-aws"
  name_prefix               = var.name_prefix
  resource_tag              = random_string.suffix.result
  global_tags               = local.global_tags
  vpc_id                    = module.network.vpc_id
  public_subnet             = module.network.public_subnet_ids[0]
  instance_key              = var.aws_keypair
  bastion_nsg_source_prefix = var.bastion_nsg_source_prefix
}


################################################################################
# 3. Create Workload Hosts to test traffic connectivity through CC
################################################################################
module "workload" {
  workload_count = var.workload_count
  source         = "github.com/locozoko/aws_lab_east/modules/terraform-zscc-workload-aws"
  name_prefix    = "${var.name_prefix}-workload"
  resource_tag   = random_string.suffix.result
  global_tags    = local.global_tags
  vpc_id         = module.network.vpc_id
  subnet_id      = module.network.workload_subnet_ids
  instance_key   = var.aws_keypair
}


################################################################################
# 4. Create specified number CC VMs per min_size / max_size which will span 
#    equally across designated availability zones per az_count. # E.g. min_size 
#    set to 4 and az_count set to 2 will create 2x CCs in AZ1 and 2x CCs in AZ2
################################################################################
# Create the user_data file with necessary bootstrap variables for Cloud Connector registration
locals {
  userdata = <<USERDATA
[ZSCALER]
CC_URL=${var.cc_vm_prov_url}
SECRET_NAME=${var.secret_name}
HTTP_PROBE_PORT=${var.http_probe_port}
USERDATA
}

# Write the file to local filesystem for storage/reference
resource "local_file" "user_data_file" {
  content  = local.userdata
  filename = "../user_data"
}

# Create the specified CC VMs via Launch Template and Autoscaling Group
module "cc_asg" {
  source                    = "github.com/locozoko/aws_lab_east/modules/terraform-zscc-asg-aws"
  name_prefix               = var.name_prefix
  resource_tag              = random_string.suffix.result
  global_tags               = local.global_tags
  cc_subnet_ids             = module.network.cc_subnet_ids
  ccvm_instance_type        = var.ccvm_instance_type
  cc_instance_size          = var.cc_instance_size
  instance_key              = var.aws_keypair
  user_data                 = local.userdata
  iam_instance_profile      = module.cc_iam.iam_instance_profile_id
  mgmt_security_group_id    = module.cc_sg.mgmt_security_group_id
  service_security_group_id = module.cc_sg.service_security_group_id

  max_size                  = var.max_size
  min_size                  = var.min_size
  target_group_arn          = module.gwlb.target_group_arn
  target_cpu_util_value     = var.target_cpu_util_value
  health_check_grace_period = var.health_check_grace_period
  launch_template_version   = var.launch_template_version
  target_tracking_metric    = var.target_tracking_metric

  warm_pool_enabled = var.warm_pool_enabled
  ### only utilzed if warm_pool_enabled set to true ###
  warm_pool_state                            = var.warm_pool_state
  warm_pool_min_size                         = var.warm_pool_min_size
  warm_pool_max_group_prepared_capacity      = var.warm_pool_max_group_prepared_capacity
  reuse_on_scale_in                          = var.reuse_on_scale_in
  lifecyclehook_instance_launch_wait_time    = var.lifecyclehook_instance_launch_wait_time
  lifecyclehook_instance_terminate_wait_time = var.lifecyclehook_instance_terminate_wait_time
  ### only utilzed if warm_pool_enabled set to true ###

  sns_enabled        = var.sns_enabled
  sns_email_list     = var.sns_email_list
  byo_sns_topic      = var.byo_sns_topic
  byo_sns_topic_name = var.byo_sns_topic_name

  depends_on = [
    local_file.user_data_file,
    null_resource.cc_error_checker,
  ]
}


################################################################################
# 5. Create IAM Policy, Roles, and Instance Profiles to be assigned to CC. 
#    Default behavior will create 1 of each IAM resource per CC VM. Set variable 
#    "reuse_iam" to true if you would like a single IAM profile created and 
#    assigned to ALL Cloud Connectors instead.
################################################################################
module "cc_iam" {
  source              = "github.com/locozoko/aws_lab_east/modules/terraform-zscc-iam-aws"
  iam_count           = 1
  name_prefix         = var.name_prefix
  resource_tag        = random_string.suffix.result
  global_tags         = local.global_tags
  cc_callhome_enabled = var.cc_callhome_enabled
  asg_enabled         = var.asg_enabled
}


################################################################################
# 6. Create Security Group and rules to be assigned to CC mgmt and and service 
#    interface(s). Default behavior will create 1 of each SG resource per CC VM. 
#    Set variable "reuse_security_group" to true if you would like a single 
#    security group created and assigned to ALL Cloud Connectors instead.
################################################################################
module "cc_sg" {
  source       = "github.com/locozoko/aws_lab_east/modules/terraform-zscc-sg-aws"
  sg_count     = 1
  name_prefix  = var.name_prefix
  resource_tag = random_string.suffix.result
  global_tags  = local.global_tags
  vpc_id       = module.network.vpc_id
}


################################################################################
# 7. Create GWLB in all CC subnets/availability zones. Create a Target Group 
#    used by cc_asg module to auto associate instances
################################################################################
module "gwlb" {
  source                = "github.com/locozoko/aws_lab_east/modules/terraform-zscc-gwlb-aws"
  name_prefix           = var.name_prefix
  resource_tag          = random_string.suffix.result
  global_tags           = local.global_tags
  vpc_id                = module.network.vpc_id
  cc_subnet_ids         = module.network.cc_subnet_ids
  http_probe_port       = var.http_probe_port
  health_check_interval = var.health_check_interval
  healthy_threshold     = var.healthy_threshold
  unhealthy_threshold   = var.unhealthy_threshold
  cross_zone_lb_enabled = var.cross_zone_lb_enabled
  asg_enabled           = var.asg_enabled
}


################################################################################
# 8. Create a VPC Endpoint Service associated with GWLB and 1x GWLB Endpoint 
#    per Cloud Connector subnet/availability zone.
################################################################################
module "gwlb_endpoint" {
  source              = "github.com/locozoko/aws_lab_east/modules/terraform-zscc-gwlbendpoint-aws"
  name_prefix         = var.name_prefix
  resource_tag        = random_string.suffix.result
  global_tags         = local.global_tags
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.cc_subnet_ids
  gwlb_arn            = module.gwlb.gwlb_arn
  acceptance_required = var.acceptance_required
  allowed_principals  = var.allowed_principals
}


################################################################################
# 9. Create Route 53 Resolver Rules and Endpoints for utilization with DNS 
#    redirection to facilitate Cloud Connector ZPA service.
################################################################################
module "route53" {
  source         = "github.com/locozoko/aws_lab_east/modules/terraform-zscc-route53-aws"
  name_prefix    = var.name_prefix
  resource_tag   = random_string.suffix.result
  global_tags    = local.global_tags
  vpc_id         = module.network.vpc_id
  r53_subnet_ids = module.network.route53_subnet_ids
  domain_names   = var.domain_names
  target_address = var.target_address
}

################################################################################
# Validation for Cloud Connector instance size and EC2 Instance Type 
# compatibilty. Terraform does not have a good/native way to raise an error at 
# the moment, so this will trigger off an invalid count value if there is an 
# improper deployment configuration.
################################################################################
resource "null_resource" "cc_error_checker" {
  count = local.valid_cc_create ? 0 : "Cloud Connector parameters were invalid. No appliances were created. Please check the documentation and cc_instance_size / ccvm_instance_type values that were chosen" # 0 means no error is thrown, else throw error
  provisioner "local-exec" {
    command = <<EOF
      echo "Cloud Connector parameters were invalid. No appliances were created. Please check the documentation and cc_instance_size / ccvm_instance_type values that were chosen" >> ../errorlog.txt
EOF
  }
}
