#!/bin/bash
# EKS ASG Migration: AL2 -> AL2023 (Hybrid Approach)
# Auto-parses resource reservations, manual input for labels/taints

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================
echo "========================================="
echo "EKS AL2 to AL2023 Migration Script"
echo "========================================="
echo ""

export CLUSTER_NAME="${CLUSTER_NAME:?Error: CLUSTER_NAME not set}"
export AWS_REGION="${AWS_REGION:?Error: AWS_REGION not set}"
export ASG_NAME="${ASG_NAME:?Error: ASG_NAME not set}"
export LAUNCH_TEMPLATE_NAME="${LAUNCH_TEMPLATE_NAME:?Error: LAUNCH_TEMPLATE_NAME not set}"
export NODE_LABELS="${NODE_LABELS:?Error: NODE_LABELS not set}"
export NODE_TAINTS="${NODE_TAINTS:-}"  # Optional: defaults to empty
export BASE_TEMPLATE_VERSION="${BASE_TEMPLATE_VERSION:-\$Latest}"


echo "Configuration:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Region: $AWS_REGION"
echo "  ASG: $ASG_NAME"
echo "  Launch Template: $LAUNCH_TEMPLATE_NAME"
echo "  Node Labels: $NODE_LABELS"
echo "  Node Taints: ${NODE_TAINTS:-<none>}"
echo "  Base Version: $BASE_TEMPLATE_VERSION"
echo ""

read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 1

# =============================================================================
# GATHER CLUSTER METADATA
# =============================================================================
echo ""
echo "Gathering cluster metadata..."

CLUSTER_INFO=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION")
export CLUSTER_ENDPOINT=$(echo "$CLUSTER_INFO" | jq -r '.cluster.endpoint')
export CLUSTER_CA=$(echo "$CLUSTER_INFO" | jq -r '.cluster.certificateAuthority.data')
export SERVICE_CIDR=$(echo "$CLUSTER_INFO" | jq -r '.cluster.kubernetesNetworkConfig.serviceIpv4Cidr')
export EKS_VERSION=$(echo "$CLUSTER_INFO" | jq -r '.cluster.version')

echo "  ✓ Cluster metadata retrieved"

# =============================================================================
# FIND AL2023 AMI
# =============================================================================
echo "Finding AL2023 AMI..."

export AL2023_AMI=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners 602401143452 \
    --filters "Name=name,Values=amazon-eks-node-al2023-x86_64-standard-${EKS_VERSION}-v*" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

echo "  ✓ AMI: $AL2023_AMI"

# =============================================================================
# GET LAUNCH TEMPLATE
# =============================================================================
echo "Retrieving launch template..."

LAUNCH_TEMPLATE=$(aws ec2 describe-launch-templates \
    --region "$AWS_REGION" \
    --launch-template-names "$LAUNCH_TEMPLATE_NAME" \
    --query 'LaunchTemplates[0]')

export LAUNCH_TEMPLATE_ID=$(echo "$LAUNCH_TEMPLATE" | jq -r '.LaunchTemplateId')
export CURRENT_VERSION=$(echo "$LAUNCH_TEMPLATE" | jq -r '.LatestVersionNumber')

CURRENT_LT_DATA=$(aws ec2 describe-launch-template-versions \
    --region "$AWS_REGION" \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$BASE_TEMPLATE_VERSION" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData')

export INSTANCE_TYPE=$(echo "$CURRENT_LT_DATA" | jq -r '.InstanceType')
export SECURITY_GROUPS=$(echo "$CURRENT_LT_DATA" | jq -c '.SecurityGroupIds')
export IAM_ARN=$(echo "$CURRENT_LT_DATA" | jq -r '.IamInstanceProfile.Arn')
export KEY_NAME=$(echo "$CURRENT_LT_DATA" | jq -r '.KeyName // empty')

OLD_USERDATA=$(echo "$CURRENT_LT_DATA" | jq -r '.UserData' | base64 -d)

echo "  ✓ Template ID: $LAUNCH_TEMPLATE_ID"
echo "  ✓ Current Version: $CURRENT_VERSION"
echo "  ✓ Using Base Version: $BASE_TEMPLATE_VERSION"

# =============================================================================
# EXTRACT CUSTOM SCRIPT (before bootstrap.sh)
# =============================================================================
echo "Extracting custom script..."

# Get everything before the bootstrap.sh line
CUSTOM_SCRIPT=$(echo "$OLD_USERDATA" | awk '/\/etc\/eks\/bootstrap.sh/{exit} {print}')

echo "  ✓ Custom script: ${#CUSTOM_SCRIPT} chars"
echo ""

read -p "Proceed to create AL2023 userdata? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 1

# =============================================================================
# CREATE AL2023 USERDATA
# =============================================================================
echo ""
echo "Creating AL2023 MIME userdata..."

# Build kubelet flags
KUBELET_FLAGS="      - --node-labels=${NODE_LABELS}"
if [ -n "$NODE_TAINTS" ]; then
    KUBELET_FLAGS="${KUBELET_FLAGS}
      - --register-with-taints=${NODE_TAINTS}"
fi

cat > /tmp/al2023-userdata.txt <<EOF
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUNDARY"

--BOUNDARY
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    apiServerEndpoint: ${CLUSTER_ENDPOINT}
    certificateAuthority: ${CLUSTER_CA}
    cidr: ${SERVICE_CIDR}
  kubelet:
    config:
      kubeReserved:
        cpu: 250m
        memory: 0.5Gi
        ephemeral-storage: 1Gi
      systemReserved:
        cpu: 250m
        memory: 0.2Gi
        ephemeral-storage: 1Gi
      evictionHard:
        memory.available: 500Mi
        nodefs.available: 10%
    flags:
${KUBELET_FLAGS}

--BOUNDARY
Content-Type: text/x-shellscript; charset="us-ascii"

${CUSTOM_SCRIPT}
--BOUNDARY--
EOF

echo "  ✓ AL2023 userdata created"

# =============================================================================
# ENCODE AND CREATE TEMPLATE VERSION
# =============================================================================
echo ""
echo "Creating launch template version..."

USER_DATA_BASE64=$(base64 -i /tmp/al2023-userdata.txt | tr -d '\n')

LT_JSON="{
  \"ImageId\": \"${AL2023_AMI}\",
  \"InstanceType\": \"${INSTANCE_TYPE}\",
  \"SecurityGroupIds\": ${SECURITY_GROUPS},
  \"IamInstanceProfile\": {\"Arn\": \"${IAM_ARN}\"},
  \"UserData\": \"${USER_DATA_BASE64}\",
  \"MetadataOptions\": {
    \"HttpTokens\": \"required\",
    \"HttpPutResponseHopLimit\": 2
  }"

if [ -n "$KEY_NAME" ]; then
    LT_JSON="${LT_JSON},\"KeyName\": \"${KEY_NAME}\""
fi

LT_JSON="${LT_JSON}}"

echo "$LT_JSON" > /tmp/launch-template.json

NEW_VERSION=$(aws ec2 create-launch-template-version \
    --region "$AWS_REGION" \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --launch-template-data file:///tmp/launch-template.json \
    --query 'LaunchTemplateVersion.VersionNumber' \
    --output text)

echo "  ✓ Version: $NEW_VERSION"
echo ""

read -p "Update ASG? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 1

# =============================================================================
# UPDATE ASG
# =============================================================================
echo ""
echo "Updating ASG..."

aws autoscaling update-auto-scaling-group \
    --region "$AWS_REGION" \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${NEW_VERSION}"

echo "  ✓ ASG updated!"
echo ""
echo "========================================="
echo "Migration Complete!"
echo "========================================="
echo ""
echo "Next: Scale up ASG and verify labels"
echo "  kubectl get nodes --show-labels | grep services=sync"
echo ""
echo "Rollback:"
echo "  aws autoscaling update-auto-scaling-group \\"
echo "    --region $AWS_REGION \\"
echo "    --auto-scaling-group-name $ASG_NAME \\"
echo "    --launch-template \"LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${CURRENT_VERSION}\""
echo ""
