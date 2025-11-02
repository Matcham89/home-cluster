#!/bin/bash
# Build and push Docker image for Kagent Slack Bot
set -e

# Configuration
REGISTRY="${REGISTRY:-docker.io/matcham89}"
IMAGE_NAME="kagent-slack-bot"
TAG="${TAG:-latest}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

echo "🔨 Building multi-platform Docker image..."
echo "   Platforms: linux/amd64, linux/arm64"

# Create buildx builder if it doesn't exist
if ! docker buildx inspect multiplatform > /dev/null 2>&1; then
    echo "Creating buildx builder..."
    docker buildx create --name multiplatform --use
fi

# Build and push for multiple platforms
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --tag "${FULL_IMAGE}" \
    --push \
    .

echo "✅ Image pushed: ${FULL_IMAGE}"
echo ""
echo "Next steps to deploy:"
echo "  1. Create secret with your Slack tokens:"
echo "     kubectl create secret generic slack-credentials \\"
echo "       --from-literal=bot-token='xoxb-your-token' \\"
echo "       --from-literal=app-token='xapp-your-token' \\"
echo "       --namespace=apps"
echo ""
echo "  2. Update k8s-deployment.yaml image to: ${FULL_IMAGE}"
echo ""
echo "  3. Deploy:"
echo "     kubectl apply -f k8s-deployment.yaml"
echo ""
echo "  4. Verify:"
echo "     kubectl logs -n apps -l app=kagent-slack-bot -f"
