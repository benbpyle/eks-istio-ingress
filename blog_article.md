Working with Kubernetes opens a world of possibilities in a software project. That's one of its biggest appeals to me as a developer. And when building with distributed systems, one of the components that often gets added into the mix is a service mesh. If you're not familiar with [the benefits of using a service mesh](https://istio.io/latest/about/service-mesh/), head over there first. It provides a nice overview of the benefits of using a mesh and how it fits into a Kubernetes deployment. 

However, a limitation of a mesh is that it deals with east/west traffic. That means service to service communication. But what about that critical north/south traffic? The kind that comes from users? Can my mesh provider in [Istio](https://istio.io/) play a role in this as well? And how about pairing with [Amazon's EKS](https://aws.amazon.com/eks/)? Let's dive in!

## API Gateway

### What is an API Gateway

First off, let's define what an API Gateway is in the context of Kubernetes.

An API Gateway acts as a reverse proxy, routing external traffic to your internal services while providing essential features like authentication, rate limiting, and request transformation. In Kubernetes environments, it serves as the entry point for all external traffic to your cluster's services.

Here are key reasons to implement an API Gateway in your Kubernetes setup:

- **Traffic Management**: Centralized control over routing, load balancing, and traffic splitting between different service versions
- **Security**: Consolidated authentication, authorization, and SSL/TLS termination
- **Monitoring**: Single point for collecting metrics, logging, and tracing data
- **API Composition**: Ability to aggregate multiple backend services into a single API
- **Rate Limiting**: Protection against abuse through request throttling
- **Protocol Translation**: Converting between different protocols (HTTP/1.1, HTTP/2, gRPC) as needed

## Istio Platform Install

All of these parts and pieces are nice, but how do they connect with AWS EKS and can I produce a working solution? This walkthrough will be fairly in-depth so starting off with the cluster build.

### EKS Cluster

Throughout this build, I'm going to favor simplicity in terms of using `eksctl`, bare YAML for my Kubernetes resources, and shell scripts where needed. This could be taken further with CDK, CloudFormation, Terraform, and other tools, but in examples that I tend to get the most out of, unless it's around that abstraction purpose, I like to see and do things vanilla.

If you've cloned the repository [https://github.com/benbpyle/eks-istio-ingress](https://github.com/benbpyle/eks-istio-ingress) and are working from it, there's a file call `cluster-config.yaml`. In that file, the cluster's configuration as well the node group requirements are defined.

```yaml
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: sandbox
  region: us-west-2

managedNodeGroups:
  - name: mng-arm
    instanceType: m6g.large
    desiredCapacity: 2
```

When I run `eksctl create cluster -f cluster-config.yaml` everything gets going. My VPC is configured, I get some subnets, a nodegroup for my cluster to work with as well as a functioning Kubernetes install.

### AWS Gateway Controller

With Istio installed, I'm marching my cluster toward allowing ingress traffic through my Istio gateway. The next step in the journey is to install an AWS Gateway Controller. This gateway controller will launch an AWS Load Balancer that can connect the outside world to my cluster. I also get a couple of pods that make that connection more physical be bridging the cloud load balancer to a resource inside my cluster.

I've created a shell script that encapsulates some of the tasks that are needed to get the controller in my cluster.

```shell
# Associate IAM OIDC provider with the cluster
eksctl utils associate-iam-oidc-provider \
    --region us-west-2 \
    --cluster sandbox \
    --approve

# Download IAM policy for the AWS Load Balancer Controller
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.3/docs/install/iam_policy.json

# Create IAM policy using the downloaded policy document
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam-policy.json

# Create service account and attach IAM policy
eksctl create iamserviceaccount \
--cluster=sandbox \
--namespace=kube-system \
--name=aws-load-balancer-controller \
--attach-policy-arn=arn:aws:iam::252703795646:policy/AWSLoadBalancerControllerIAMPolicy \
--override-existing-serviceaccounts \
--region us-west-2 \
--approve

# Add AWS EKS Helm repository
helm repo add eks https://aws.github.io/x-charts

# Apply AWS Load Balancer Controller CRDs 
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"

# Install AWS Load Balancer Controller using Helm
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=sandbox --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller
```

Running the `gateway_controller.sh` script is as follows:

```bash
chmod 755 gateway-controller.sh
./kubernetes/alb/install-gateway-controller.sh
```

A glimpse into the new cluster with Istio and the gateway controller looks
like this.

![Gateway Controller](./istio_install.jpg)

### Kubernetes Gateway CRDs

Resources in Kubernetes need definition files so that the server can
validate that my resource configuration is applied correctly. Some
Kubernetes servers don't come prepared with the correct Gateway Resource
Definitions. Let's get that taken care of.

```bash
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.2.1" | kubectl apply -f -; }
```

### Installing Istio

I need to get Istio installed and into my cluster if I want to have it
control my ingress traffic.

* Up first, download and unzip the [Istio binaries](https://istio.io/latest/docs/setup/getting-started/#download)
* Run the `istioctl` command.

```bash
# sets up some namespaces
kubectl apply -f kubernetes/namespaces.yaml
istioctl install -f kubernetes/istio/istio-installation.yaml
```

Let's recap so far!

* ✓ Created an EKS cluster with managed node groups using eksctl
* ✓ Associated IAM OIDC provider with the cluster
* ✓ Created and attached IAM policy for AWS Load Balancer Controller
* ✓ Installed AWS Load Balancer Controller via Helm
* ✓ Added Kubernetes Gateway CRDs
* ✓ Downloaded and installed Istio using istioctl
* ✓ Configured Istio with custom installation settings

Now onto my application!

## Deploying Rust Code

To demonstrate this solution, I've built two small Rust Web APIs powered by
Axum. Service-B will host the public endpoint that has a dependency on
Service-A and will use a consumer's input to build a final payload.

### Deploy Service-A

I'm going to deploy Service-A first because it has no dependencies. But
first, I'm creating my namespace to house this code.

```shell
kubectl apply -f service-a-service.yaml
```

I've included a few other Istio resources in this build below.

* Deployment has the pod definition and spec
* Service is a standard Kubernetes resource that sets up the port
* DestinationRule is where I'm building some outlier configuration. I'll
  address this in a future article where I talk about Service Mesh Circuit
  Breaking

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: rust-services
  labels:
    app: service-a
  name: service-a
spec:
  selector:
    matchLabels:
      app: service-a
  replicas: 1
  template:
    metadata:
      annotations:
        # Used in other solutions for Datadog
        traffic.sidecar.istio.io/excludeOutboundPorts: "8126"
      name: service-a
      namespace: rust-services
      labels:
        app: service-a
        sidecar.istio.io/inject: "true"
    spec:
      nodeSelector:
        eks.amazonaws.com/nodegroup: mng-arm
      containers:
        - name: service-a
          image: public.ecr.aws/f8u4w2p3/rust-service-a:latest
          ports:
            - containerPort: 3000
              name: http-web-svc
          env:
            - name: HOST_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: BIND_ADDRESS
              value: "0.0.0.0:3000"
            - name: DD_TRACING_ENABLED
              value: "true"
            - name: AGENT_ADDRESS
              value: $(HOST_IP)
            - name: RUST_LOG
              value: "info"
---
apiVersion: v1
kind: Service
metadata:
  namespace: rust-services
  labels:
    app: service-a
  name: service-a
spec:
  selector:
    app: service-a
  ports:
    - name: default
      protocol: TCP
      port: 80
      targetPort: 3000

---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: service-a-destination-rule
  namespace: rust-services
spec:
  host: service-a
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 0
      consecutiveGatewayErrors: 5
      interval: 15s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
      minHealthPercent: 50

```

### Deploy Service-B

This service is the receiver of outside traffic (via Istio) and will make calls into Service-A and communicate over the service mesh (Istio). An all-Istio managed solution! Let's have a look at the service first and then see about connecting the new Gateway to this inbound traffic handling service. Notice it'll look very much like the Service-A definition above.

```shell
kubectl apply -f service-b-service.yaml
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: rust-services
  labels:
    app: service-b
  name: service-b
spec:
  selector:
    matchLabels:
      app: service-b
  replicas: 1
  template:
    metadata:
      annotations:
        traffic.sidecar.istio.io/excludeOutboundPorts: "8126"
      namespace: rust-services
      labels:
        app: service-b
        sidecar.istio.io/inject: "true"
    spec:
      nodeSelector:
        eks.amazonaws.com/nodegroup: mng-arm
      containers:
        - name: service-b
          image: public.ecr.aws/f8u4w2p3/rust-service-b:2-routes
          ports:
            - containerPort: 3000
              name: http-web-svc
          env:
            - name: HOST_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: BIND_ADDRESS
              value: "0.0.0.0:3000"
            - name: DD_TRACING_ENABLED
              value: "false"
            - name: AGENT_ADDRESS
              value: $(HOST_IP)
            - name: RUST_LOG
              value: "info"
            - name: SERVICE_A_URL
              value: http://service-a
---
apiVersion: v1
kind: Service
metadata:
  namespace: rust-services
  labels:
    app: service-b
  name: service-b
spec:
  selector:
    app: service-b
  ports:
    - name: default
      protocol: TCP
      port: 80
      targetPort: 3000
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: service-b-destination-rule
  namespace: rust-services
spec:
  host: service-b
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 0
      consecutiveGatewayErrors: 5
      interval: 15s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
      minHealthPercent: 50
```

### Connecting Service-B to the Gateway

The last 2 pieces of the puzzle include adding the actual Gateway itself and connecting the Gateway to the Application Load Balancer defined in AWS. What I really enjoy about using Istio as an Ingress/API Gateway is that I use constructs like VirtualService and HTTPRoute to manage my traffic flow. These are the same resources I use when working with the Service Mesh aspects, so I just get the same feelings. It also means I know how to troubleshoot problems with these resources. And I can use my normal observability tools like Kiali and Datadog. More on both of those in a future article.

So let's get to configuring the Istio Gateway.

```bash
kubectl apply -f kubernetes/istio/gateway.yaml
```

The contents of the `gateway.yaml` file include a `Gateway` resource and a `VirtualService`. If you've used Istio before, you'll notice most of the VirtualService looks like what you've seen before. But pay special attention to the gateways section. This is where I make the connection the Gateway I defined right above it. And in the Gateway resource, notice that it's in the same namespace as the rest of the application services. `rust-services`. Those two details tripped me up as I was first working with Istio as an Ingress Gateway.

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: application-gateway
  namespace: rust-services
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: service-b
  namespace: rust-services
spec:
  hosts:
    - "*"
  gateways:
    - application-gateway
  http:
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: service-b
```

## Putting it All Together

What would a walkthrough be without highlighting how to test our work? Being that this is an API focused article, and a simple one at that, I've got a HealthCheck and an actual endpoint to run through. To make this happen, you'll need the DNS name for the Application Load Balancer you created earlier. You can grab that from the AWS Console.

For the HealthCheck:

```bash
GET http://<ALB URL>/health

HTTP/1.1 200 OK
Date: Mon, 07 Jul 2025 11:53:17 GMT
Content-Type: application/json
Content-Length: 20
Connection: keep-alive
x-envoy-upstream-service-time: 1
server: istio-envoy

{
  "status": "Healthy"
}
Response file saved.
> 2025-07-07T065317.200.json

Response code: 200 (OK); Time: 184ms (184 ms); Content length: 20 bytes (20 B)
```

Now let's do the same thing for the actual endpoint>

```bash
GET http://<ALB URL>>?name=A+Field

HTTP/1.1 200 OK
Date: Mon, 07 Jul 2025 11:54:47 GMT
Content-Type: application/json
Content-Length: 59
Connection: keep-alive
x-envoy-upstream-service-time: 3
server: istio-envoy

{
  "key_one": "(A Field)Field 1",
  "key_two": "(A Field)Field 2"
}
Response file saved.
> 2025-07-07T065447.200.json

Response code: 200 (OK); Time: 186ms (186 ms); Content length: 59 bytes (59 B)

```

## Cleaning Up

One thing about working with Kubernetes vs Serverless is that my resources are going to cost me dollars even when I'm not using them. This is because the EKS control plane is billing hourly and I've allocated two EC2 instances that also are running full time to host my pods. Being cost conscious is important, so here's how to clean up the resources created above.

```bash
kubectl delete -f kubernetes/alb/alb-ingress.yaml
kubectl delete -f kubernetes/istio/gateway.yaml
kubectl delete -f kubernetes/service/service-b.yaml
istioctl uninstall --purge
kubectl delete -f kubernetes/namespaces.yaml
```

## Wrapping Up

I hope this article gives you the confidence to dive into connection Istio and EKS when building an API Gateway for your APIs. The Gateway spec offers much more control over the flow of your traffic and is the preferred way going forward in the Kubernetes ecosystem. However, there's not a ton of documentation out there and I could find little in the way of plain YAML the showed how these pieces come together. With that said, I barely scratched the surface of the power and flexibility this solution provides.

Kubernetes gets the rap of being complex and difficult to manage but one of the goals of this article was to show that you can achieve a powerful Gateway with very minimal setup and configuration. I don't believe there's more YAML in this solution than what I write in a Serverless build. I also don't believe that there are more "parts". I'm just more in control of them.

The last bit I'll say is that I'd love for you to try out the solution yourself. Get your hands dirty so to speak and run through the different operations required to make this happen. Feel free to clone this [GitHub Repository](https://github.com/benbpyle/eks-istio-ingress) and get started. The README in that repos will help you get going as well.

Thanks for reading and happy building!
