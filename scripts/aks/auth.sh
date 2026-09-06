# Get current public IP
CURRENT_IP=$(curl -4 -fsSL https://ifconfig.me)

# Add it to AKS authorized IP ranges
az aks update \
  --resource-group rg-taskapi-stg \
  --name aks-taskapi-stg-f41930 \
  --api-server-authorized-ip-ranges "AzureCloud,${CURRENT_IP}/32" \
  --output none

# Wait for propagation
sleep 20

# Re-fetch credentials
az aks get-credentials \
  --resource-group rg-taskapi-stg \
  --name aks-taskapi-stg-f41930 \
  --overwrite-existing

# Verify API access
kubectl get nodes

# Check if rollout exists
kubectl get rollout backend -n task-api

# Now watch live
kubectl argo rollouts get rollout backend -n task-api -w

kubectl argo rollouts get rollout frontend -n task-api -w
