# Istio Ingress with AWS ALB

This repository contains Kubernetes manifests for setting up Istio with an AWS Application Load Balancer (ALB) and deploying a service from AWS ECR.

## Components

1. **Istio Installation**: Installs Istio with an ingress gateway
2. **AWS Application Load Balancer**: Configures an ALB to route traffic to the Istio ingress gateway
3. **Application Service**: Deploys a service using an image from AWS ECR
4. **Istio Gateway and VirtualService**: Configures Istio to route traffic to the application service

## Prerequisites

- AWS CLI configured with appropriate permissions
- kubectl installed and configured to access your cluster
- Helm (optional, for Istio installation)

## Deployment Instructions

### 1. Create EKS cluster with eksctl

```bash
# Create the EKS cluster using the configuration file
eksctl create cluster -f kubernetes/cluster/cluster-config.yaml
```

This will create a cluster named "sandbox" in the us-west-2 region with 2 m6g.large ARM instances.

### 2. Install AWS Load Balancer Controller (Gateway Controller)

```bash
# Associate IAM OIDC provider with the cluster
eksctl utils associate-iam-oidc-provider \
    --region us-west-2 \
    --cluster sandbox \
    --approve

# Create IAM policy for the AWS Load Balancer Controller
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://kubernetes/alb/iam-policy.json

# Create IAM service account for the controller
eksctl create iamserviceaccount \
    --cluster=sandbox \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=arn:aws:iam::<your-aws-account-id>:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --region us-west-2 \
    --approve

# Install the AWS Load Balancer Controller using Helm
helm repo add eks https://aws.github.io/x-charts
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=sandbox \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller
```

### 3. Set up environment variables

```bash
export AWS_ACCOUNT_ID=<your-aws-account-id>
export AWS_REGION=<your-aws-region>
```

### 4. Create namespaces

```bash
kubectl apply -f kubernetes/namespaces.yaml
```

### 5. Install Istio

Using istioctl:
```bash
istioctl install -f kubernetes/istio/istio-installation.yaml
```

Or using Helm:
```bash
helm install istio-base istio/base -n istio-system
helm install istiod istio/istiod -n istio-system -f <(istioctl profile dump -f kubernetes/istio/istio-installation.yaml)
helm install istio-ingress istio/gateway -n istio-system
```

### 6. Deploy the application service

```bash
envsubst < kubernetes/service/service-a.yaml | kubectl apply -f -
envsubst < kubernetes/service/service-b.yaml | kubectl apply -f -
```

### 7. Configure Istio routing

```bash
kubectl apply -f kubernetes/istio/gateway.yaml
```

### 8. Set up the AWS ALB

```bash
kubectl apply -f kubernetes/alb/alb-ingress.yaml
```

### 9. Verify the deployment

```bash
# Get the ALB URL
kubectl get ingress -n istio-system

# Check if the application pods are running
kubectl get pods -n application

# Check if the Istio gateway is configured
kubectl get gateway -n application
kubectl get virtualservice -n application
```

## Architecture

```
Internet → AWS ALB → Istio Ingress Gateway → Istio VirtualService → Application Service
```

## Troubleshooting

- Check Istio ingress gateway logs:
  ```bash
  kubectl logs -n istio-system -l app=istio-ingressgateway
  ```

- Check application service logs:
  ```bash
  kubectl logs -n application -l app=application-service
  ```

- Verify Istio configuration:
  ```bash
  istioctl analyze -n application
  ```

## Cleanup

```bash
kubectl delete -f kubernetes/alb/alb-ingress.yaml
kubectl delete -f kubernetes/istio/gateway.yaml
kubectl delete -f kubernetes/service/service-b.yaml
istioctl uninstall --purge
kubectl delete -f kubernetes/namespaces.yaml
```
