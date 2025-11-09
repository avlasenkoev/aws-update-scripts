# AWS EKS ASG Update Scripts

Scripts for managing EKS Auto Scaling Group AMI updates and migrations.

## Scripts

- **eks_migrate_asg_from_linux_2_to_linux_2023.sh** - Migrate ASG from Amazon Linux 2 to AL2023
- **eks_update_asg_ami.sh** - Update existing AL2023 ASG to latest AMI

## Environment Variables

### Migration Script (AL2 → AL2023)

| Variable | Required | Description |
|----------|----------|-------------|
| `CLUSTER_NAME` | Yes | EKS cluster name |
| `AWS_REGION` | Yes | AWS region |
| `ASG_NAME` | Yes | Auto Scaling Group name |
| `LAUNCH_TEMPLATE_NAME` | Yes | Launch template name |
| `NODE_LABELS` | Yes | Node labels (e.g., "services=sync,env=prod") |
| `NODE_TAINTS` | No | Node taints (optional) |
| `BASE_TEMPLATE_VERSION` | No | Template version to base from (default: $Latest) |

### Update Script (AL2023 AMI Update)

| Variable | Required | Description |
|----------|----------|-------------|
| `CLUSTER_NAME` | Yes | EKS cluster name |
| `AWS_REGION` | Yes | AWS region |
| `LAUNCH_TEMPLATE_NAME` | Yes | Launch template name |
| `ASG_NAME` | Yes | Auto Scaling Group name |

## Usage

```bash
# Migrate from AL2 to AL2023
export CLUSTER_NAME="my-cluster"
export AWS_REGION="us-east-1"
export ASG_NAME="my-asg"
export LAUNCH_TEMPLATE_NAME="my-template"
export NODE_LABELS="services=sync,env=prod"

./eks_migrate_asg_from_linux_2_to_linux_2023.sh
```

```bash
# Update AL2023 AMI to latest
export CLUSTER_NAME="my-cluster"
export AWS_REGION="us-east-1"
export LAUNCH_TEMPLATE_NAME="my-template"
export ASG_NAME="my-asg"

./eks_update_asg_ami.sh
```

## Monitor Instance Refresh Status

```bash
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name $ASG_NAME \
  --query 'InstanceRefreshes[0].StatusReason' \
  --output text
```

## Prerequisites

- AWS CLI installed and configured
- `jq` command-line JSON processor
- AWS IAM permissions:
  - `eks:DescribeCluster`
  - `ec2:DescribeImages`
  - `ec2:DescribeLaunchTemplates`
  - `ec2:DescribeLaunchTemplateVersions`
  - `ec2:CreateLaunchTemplateVersion`
  - `ec2:ModifyLaunchTemplate`
  - `autoscaling:UpdateAutoScalingGroup`
  - `autoscaling:DescribeInstanceRefreshes`

## Notes

Both scripts include interactive confirmations and rollback instructions.
