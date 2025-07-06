# Istio Ingress with AWS ALB

This repository contains Kubernetes manifests for setting up Istio with an AWS Application Load Balancer (ALB) and deploying a service from AWS ECR.

## Components

1. **Istio Installation**: Installs Istio with an ingress gateway
2. **AWS Application Load Balancer**: Configures an ALB to route traffic to the Istio ingress gateway
3. **Application Service**: Deploys a service using an image from AWS ECR
4. **Istio Gateway and VirtualService**: Configures Istio to route traffic to the application service

## Prerequisites

- Kubernetes cluster running on AWS
- AWS Load Balancer Controller installed in the cluster
- AWS CLI configured with appropriate permissions
- kubectl installed and configured to access your cluster
- Helm (optional, for Istio installation)

## Deployment Instructions

### 1. Set up environment variables

```bash
export AWS_ACCOUNT_ID=<your-aws-account-id>
export AWS_REGION=<your-aws-region>
```

### 2. Create namespaces

```bash
kubectl apply -f kubernetes/namespaces.yaml
```

### 3. Install Istio

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

### 4. Deploy the application service

```bash
envsubst < kubernetes/service/service-b.yaml | kubectl apply -f -
```

### 5. Configure Istio routing

```bash
kubectl apply -f kubernetes/istio/gateway.yaml
```

### 6. Set up the AWS ALB

```bash
kubectl apply -f kubernet[blog_article.md](../../rust/circuit-breaking/blog_article.md)[blog_article.md](../../rust/circuit-breaking/blog_article.md)es/alb/alb-ingress.yaml
```

### 7. Verify the deployment

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