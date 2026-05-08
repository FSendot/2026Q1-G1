# `modules/onprem_sim`

Provisions a separate VPC that simulates an on-premise datacenter, plus the AWS-side glue (`aws_customer_gateway`, `aws_vpn_connection`) needed to bring up a Site-to-Site IPsec tunnel against the Virtual Private Gateway exposed by [`modules/network`](../network).

The simulated router is a single EC2 instance running [strongSwan](https://www.strongswan.org/) and Quagga BGP, deployed by embedding the existing CloudFormation template at [`templates/vpn-gateway-strongswan.yml`](../../templates/vpn-gateway-strongswan.yml) inside an `aws_cloudformation_stack`. Terraform pipes the AWS-generated tunnel parameters (PSKs, inside/outside IPs, BGP ASNs) into the stack so the bootstrap script can configure both tunnels deterministically.

The module is intentionally minimal — single AZ, permissive security group, no flow logs — because the whole point is to *simulate* an external network for the academic lab, not to harden one.

## Resources

- `aws_vpc.onprem` + `aws_internet_gateway.igw` — the simulated on-premise VPC (default `192.168.0.0/16`).
- `aws_subnet.public` + `aws_route_table.public` + `aws_route.public_default` + `aws_route_table_association.public` — single public subnet in `var.azs[0]` with default route to the IGW and `map_public_ip_on_launch = true`.
- `aws_security_group.router` — permissive SG: ingress for IKE (UDP 500/4500) and ESP/AH (IP proto 50/51) from the world, all inbound from `var.aws_vpc_cidr`, all egress. The CFN template attaches its own SG to the EC2 NIC; this one is here for diagnostics and is exported via outputs but not directly attached.
- `aws_eip.gw` — Elastic IP allocated up-front so its `public_ip` is stable as `aws_customer_gateway.ip_address` and as `pEipAllocationId` for the CFN stack.
- `aws_customer_gateway.cgw` — `bgp_asn = 65000` (matches `pLocalBgpAsn` default of the template), `type = "ipsec.1"`, `ip_address = aws_eip.gw.public_ip`.
- `aws_vpn_connection.vpn` — BGP-based (`static_routes_only = false`) Site-to-Site VPN between `var.vpn_gateway_id` and the customer gateway above. AWS auto-generates two tunnels with their PSKs and inside `/30` link networks.
- `aws_secretsmanager_secret.tunnel{1,2}` + `aws_secretsmanager_secret_version.tunnel{1,2}` — store each tunnel's PSK as `{"psk": "<value>"}`, matching the `jq -r '.SecretString' | jq -r '.psk'` parser in the CFN template's `set-psk.sh`.
- `aws_cloudformation_stack.strongswan` — deploys [`templates/vpn-gateway-strongswan.yml`](../../templates/vpn-gateway-strongswan.yml). All tunnel/BGP/EIP/VPC parameters are wired from the resources above.

## Inputs

| Name                        | Type           | Default              | Description                                                                                  |
| --------------------------- | -------------- | -------------------- | -------------------------------------------------------------------------------------------- |
| `project`                   | `string`       | n/a                  | Prefix for resource names.                                                                   |
| `vpn_gateway_id`            | `string`       | n/a                  | ID of the AWS-side VGW (from `modules/network`).                                             |
| `aws_vpc_cidr`              | `string`       | n/a                  | CIDR of the AWS-side VPC, used to authorise return traffic in the on-prem SG.                |
| `azs`                       | `list(string)` | n/a                  | Available AZs; only the first is used for the on-prem public subnet.                         |
| `onprem_vpc_cidr`           | `string`       | `"192.168.0.0/16"`   | CIDR of the simulated on-prem VPC. Must not overlap `aws_vpc_cidr`.                          |
| `onprem_public_subnet_cidr` | `string`       | `"192.168.1.0/24"`   | CIDR of the public subnet that hosts the strongSwan EC2.                                     |
| `instance_type`             | `string`       | `"t3a.micro"`        | EC2 type for the VPN gateway. Restricted to the values allowed by the CFN template.          |
| `tags`                      | `map(string)`  | `{}`                 | Common tags merged with `Component = "onprem-sim"`.                                          |

## Outputs

| Name                       | Description                                                                  |
| -------------------------- | ---------------------------------------------------------------------------- |
| `onprem_vpc_id`            | ID of the simulated on-prem VPC.                                             |
| `onprem_vpc_cidr`          | CIDR of the simulated on-prem VPC.                                           |
| `onprem_public_subnet_id`  | ID of the public subnet hosting the strongSwan EC2.                          |
| `vpn_gateway_public_ip`    | Public EIP of the strongSwan EC2 (also the CGW `ip_address`).                |
| `customer_gateway_id`      | ID of the Customer Gateway.                                                  |
| `vpn_connection_id`        | ID of the Site-to-Site VPN connection.                                       |
| `cloudformation_stack_id`  | ID of the embedded CloudFormation stack that runs the EC2 + strongSwan.      |

## Notes

- **Why an embedded CloudFormation stack?** The template at [`templates/vpn-gateway-strongswan.yml`](../../templates/vpn-gateway-strongswan.yml) is the source of truth for the strongSwan + Quagga bootstrap. Translating its ~940 lines of `cfn-init` into Terraform `user_data` would invite drift; embedding it via `aws_cloudformation_stack` keeps the YAML authoritative.
- **AMI drift suppression.** The template's `pAmiId` resolves an SSM Parameter to the latest Amazon Linux 2 AMI, which moves over time. The stack uses `lifecycle { ignore_changes = [parameters["pAmiId"]] }` to avoid perpetual drift; taint the stack manually when an AMI rotation is intended.
- **PSK handling.** `aws_vpn_connection.tunnel{1,2}_preshared_key` is sensitive throughout; it is only ever read into `aws_secretsmanager_secret_version.secret_string` and never surfaced as an output.
- **AWS Academy.** The CFN template references `arn:aws:iam::<account>:instance-profile/LabInstanceProfile`, which exists in the lab account. Secrets Manager reads use the default permissions on `LabRole`/`LabInstanceProfile`.
- **Idempotency caveat.** `aws_cloudformation_stack` triggers an UPDATE whenever any parameter changes. Because the AWS-generated PSKs and inside IPs are stable across plans (pinned in state by the `aws_vpn_connection` resource), re-running `terraform apply` with no input changes produces no diff once the first apply succeeds.
- **Checkov skips.** The permissive security group (`CKV_AWS_24`, `CKV_AWS_260`), the lack of secret rotation (`CKV2_AWS_57`) and the AWS-managed KMS key on Secrets Manager (`CKV_AWS_149`) are intentional trade-offs for this academic simulation and are skipped inline with explanatory comments.
