#!/bin/bash
set -e

# =============================================================================
# CONFIGURATION
# =============================================================================
echo "========================================="
echo "EKS AMI Update Script"
echo "========================================="

export CLUSTER_NAME="${CLUSTER_NAME:?Error: CLUSTER_NAME not set}"
export AWS_REGION="${AWS_REGION:?Error: AWS_REGION not set}"
export LAUNCH_TEMPLATE_NAME="${LAUNCH_TEMPLATE_NAME:?Error: LAUNCH_TEMPLATE_NAME not set}"
export ASG_NAME="${ASG_NAME:?Error: ASG_NAME not set}"

echo "Configuration:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Region: $AWS_REGION"
echo "  Launch Template: $LAUNCH_TEMPLATE_NAME"
echo "  ASG: $ASG_NAME"
echo ""

# =============================================================================
# GET EKS VERSION
# =============================================================================
echo "Getting cluster version..."
EKS_VERSION=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.version' --output text)
echo "  ✓ EKS Version: $EKS_VERSION"

# =============================================================================
# FIND AL2023 AMI
# =============================================================================
echo "Finding AL2023 AMI for version $EKS_VERSION..."
AL2023_AMI=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners 602401143452 \
    --filters "Name=name,Values=amazon-eks-node-al2023-x86_64-standard-${EKS_VERSION}-v*" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)
echo "  ✓ AMI: $AL2023_AMI"

# =============================================================================
# GET CURRENT TEMPLATE
# =============================================================================
echo "Getting launch template..."
LAUNCH_TEMPLATE_ID=$(aws ec2 describe-launch-templates \
    --region "$AWS_REGION" \
    --launch-template-names "$LAUNCH_TEMPLATE_NAME" \
    --query 'LaunchTemplates[0].LaunchTemplateId' \
    --output text)

CURRENT_LT_DATA=$(aws ec2 describe-launch-template-versions \
    --region "$AWS_REGION" \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions '$Latest' \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData' \
    --output json)

echo "  ✓ Template ID: $LAUNCH_TEMPLATE_ID"


# =============================================================================
# CREATE NEW VERSION WITH UPDATED AMI
# =============================================================================
echo "Creating new template version..."

# Update only the AMI, keep everything else
NEW_LT_DATA=$(echo "$CURRENT_LT_DATA" | jq --arg ami "$AL2023_AMI" '.ImageId = $ami')

echo "$NEW_LT_DATA" > /tmp/launch-template.json

NEW_VERSION=$(aws ec2 create-launch-template-version \
    --region "$AWS_REGION" \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --launch-template-data file:///tmp/launch-template.json \
    --query 'LaunchTemplateVersion.VersionNumber' \
    --output text)

echo "  ✓ Created version: $NEW_VERSION"

# =============================================================================
# UPDATE ASG
# =============================================================================
read -p "Update ASG to use new version? (yes/no): " update_asg
if [[ "$update_asg" == "yes" ]]; then
    aws autoscaling update-auto-scaling-group \
        --region "$AWS_REGION" \
        --auto-scaling-group-name "$ASG_NAME" \
        --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${NEW_VERSION}"
    echo "  ✓ ASG updated to version $NEW_VERSION"
fi

echo ""
echo "========================================="
echo "Complete!"
echo "========================================="
echo ""
echo "Next: Start instance refresh:"
echo "  aws autoscaling start-instance-refresh \\"
echo "    --auto-scaling-group-name $ASG_NAME \\"
echo "    --preferences '{\"MinHealthyPercentage\":90}'"


# =============================================================================
# SET AS DEFAULT
# =============================================================================
read -p "Set version $NEW_VERSION as default? (yes/no): " set_default
if [[ "$set_default" == "yes" ]]; then
    aws ec2 modify-launch-template \
        --region "$AWS_REGION" \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --default-version "$NEW_VERSION"
    echo "  ✓ Version $NEW_VERSION set as default"
fi
