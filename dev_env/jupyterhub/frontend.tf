#####################
# Frontend selection
#
# Only one of the two choices below can be enabled at a time
# Run terraform init if changing between the two

###################################################################
# Use an API Gateway connected to a NLB as the Jupyterhub Frontend
# 
# This options mostly works except that websockets fail to properly
# be routed through the REST API gateway, more work would be needed
# to get it working.

# module "frontend" {
#   source = "./modules/api_gateway"
# 
#   project = var.project
#   venue = var.venue
#   venue_prefix = var.venue_prefix
#   resource_prefix = var.resource_prefix
#   load_balancer_port = var.load_balancer_port
#   jupyter_proxy_port = var.jupyter_proxy_port
# 
#   vpc_id = data.aws_ssm_parameter.vpc_id.value
#   lb_subnet_ids = local.subnet_map["private"]
#   security_group_id = aws_security_group.jupyter_lb_sg.id
#   autoscaling_group_name = module.eks.eks_managed_node_groups_autoscaling_group_names[0]
# }

#################################################################
# Set up these data values to allow overriding of values by variables

data "aws_ssm_parameter" "ssAcctNum" {
  name = "/unity/shared-services/aws/account"
}

data "aws_ssm_parameter" "proxy_url" {
  name = "arn:aws:ssm:us-west-2:${data.aws_ssm_parameter.ssAcctNum.value}:parameter/unity/shared-services/domain"
}

locals {
  # Extract info on the proxy from the SSM parameter
  proxy_proto         = "https"
  proxy_address       = data.aws_ssm_parameter.proxy_url.value
  proxy_port          = 4443

  # Allow overriding from variables
  url_terminus_path  = "jupyter"
  load_balancer_port = var.load_balancer_port != null ? var.load_balancer_port : local.proxy_port
  jupyter_base_url   = var.jupyter_base_url != null   ? var.jupyter_base_url : "${local.proxy_proto}://${local.proxy_address}:${local.proxy_port}"
  #jupyter_base_path  = var.jupyter_base_path != null ? var.jupyter_base_path : "${var.project}/${var.venue}/${local.url_terminus_path}"
  jupyter_base_path  = var.jupyter_base_path != null ? var.jupyter_base_path : "${local.url_terminus_path}"
}

#################################################################
# Use only a Application Load Balancer as the Jupyterhub Frontend

module "frontend" {
  source = "./modules/load_balancer"

  project = var.project
  venue = var.venue
  venue_prefix = var.venue_prefix
  resource_prefix = var.resource_prefix
  load_balancer_port = local.load_balancer_port
  jupyter_proxy_port = var.jupyter_proxy_port

  jupyter_base_url = local.jupyter_base_url
  jupyter_base_path = local.jupyter_base_path

  vpc_id = data.aws_ssm_parameter.vpc_id.value
  lb_subnet_ids = local.subnet_map["public"]
  security_group_id = aws_security_group.jupyter_lb_sg.id
  autoscaling_group_name = module.eks.eks_managed_node_groups_autoscaling_group_names[0]
}

#################################################################
# Initialize connection to HTTP proxy
resource "aws_ssm_parameter" "serviceproxy_config" {
  depends_on = [module.frontend]
  name       = "/unity/${var.project}/${var.venue}/cs/management/proxy/configurations/042-jupyterlab"
  type       = "String"
  value       = <<-EOT
    SSLProxyEngine on
    <Location /${var.project}/${var.venue}/${local.url_terminus_path}>
      Header always set Strict-Transport-Security "max-age=63072000"
      ProxyPass "${module.frontend.internal_base_url}/${local.jupyter_base_path}" upgrade=websocket
      ProxyPassReverse "${module.frontend.internal_base_url}/${local.jupyter_base_path}"
      ProxyPreserveHost on
      RequestHeader     set "X-Forwarded-Proto" expr=%%{REQUEST_SCHEME}
    </Location>
EOT
}

resource "aws_lambda_invocation" "unity_proxy_lambda_invocation" {
  depends_on    = [aws_ssm_parameter.serviceproxy_config]
  function_name = "${var.project}-${var.venue}-httpdproxymanagement"
  input         = "{}"
  triggers = {
    redeployment = sha1(jsonencode([
      aws_ssm_parameter.serviceproxy_config
    ]))
  }
}
