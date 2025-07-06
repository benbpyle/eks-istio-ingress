eksctl utils associate-iam-oidc-provider \
    --region us-west-2 \
    --cluster sandbox \
    --approve

# curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.3/docs/install/iam_policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam-policy.json

eksctl create iamserviceaccount \
--cluster=sandbox \
--namespace=kube-system \
--name=aws-load-balancer-controller \
--attach-policy-arn=arn:aws:iam::252703795646:policy/AWSLoadBalancerControllerIAMPolicy \
--override-existing-serviceaccounts \
--region us-west-2 \
--approve

helm repo add eks https://aws.github.io/x-charts
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=sandbox --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller

