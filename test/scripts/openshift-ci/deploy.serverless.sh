#!/usr/bin/env bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu

waitforpodlabeled() {
  local ns=${1?namespace is required}; shift
  local podlabel=${1?pod label is required}; shift

  echo "Waiting for pod -l $podlabel to be created"
  until oc get pod -n "$ns" -l $podlabel -o=jsonpath='{.items[0].metadata.name}' >/dev/null 2>&1; do
    sleep 1
  done
}

waitpodready() {
  local ns=${1?namespace is required}; shift
  local podlabel=${1?pod label is required}; shift

  waitforpodlabeled "$ns" "$podlabel"
  sleep 10
  oc get pod -n $ns -l $podlabel

  echo "Waiting for pod -l $podlabel to become ready"
  oc wait --for=condition=ready --timeout=600s pod -n $ns -l $podlabel || (oc get pod -n $ns -l $podlabel && false)
}

# Deploy Serverless operator
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-serverless
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: serverless-operators
  namespace: openshift-serverless
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-serverless
spec:
  channel: stable
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
EOF

waitpodready "openshift-serverless" "name=knative-openshift"
waitpodready "openshift-serverless" "name=knative-openshift-ingress"
waitpodready "openshift-serverless" "name=knative-operator"

# Install KNative
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: knative-serving
  labels:
    testing.kserve.io/add-to-mesh: "true"
---
apiVersion: operator.knative.dev/v1beta1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: knative-serving
  annotations:
    serverless.openshift.io/default-enable-http2: "true"
spec:
  deployments:
    - annotations:
        sidecar.istio.io/inject: "true"
        sidecar.istio.io/rewriteAppHTTPProbers: "true"
      name: activator
    - annotations:
        sidecar.istio.io/inject: "true"
        sidecar.istio.io/rewriteAppHTTPProbers: "true"
      name: autoscaler
  ingress:
    istio:
      enabled: true
EOF

# Apparently, as part of KNative installation, deployments can be restarted because
# of configuration changes, leading to waitpodready to fail sometimes.
# Let's sleep 2minutes to let the KNative operator to stabilize the installation before
# checking for the readiness of KNative stack.
sleep 120

waitpodready "knative-serving" "app=controller"
waitpodready "knative-serving" "app=net-istio-controller"
waitpodready "knative-serving" "app=net-istio-webhook"
waitpodready "knative-serving" "app=autoscaler-hpa"
waitpodready "knative-serving" "app=domain-mapping"
waitpodready "knative-serving" "app=webhook"
waitpodready "knative-serving" "app=activator"
waitpodready "knative-serving" "app=autoscaler"

# Install the Gateways
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  labels:
    experimental.istio.io/disable-gateway-port-translation: "true"
  name: knative-local-gateway
  namespace: istio-system
spec:
  ports:
    - name: http2
      port: 80
      protocol: TCP
      targetPort: 8081
  selector:
    istio: ingressgateway
  type: ClusterIP
---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: knative-ingress-gateway
  namespace: knative-serving
spec:
  selector:
    istio: ingressgateway
  servers:
    - hosts:
        - '*'
      port:
        name: https
        number: 443
        protocol: HTTPS
      tls:
        credentialName: wildcard-certs
        mode: SIMPLE
---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: knative-local-gateway
  namespace: knative-serving
spec:
  selector:
    istio: ingressgateway
  servers:
    - hosts:
        - '*'
      port:
        name: http
        number: 8081
        protocol: HTTP
---
apiVersion: v1
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUMzekNDQWNjQ0FRQXdEUVlKS29aSWh2Y05BUUVMQlFBd0tURVRNQkVHQTFVRUNnd0tRMnhoYzJnZ1NXNWoKTGpFU01CQUdBMVVFQXd3SlkyeGhjMmd1WTI5dE1CNFhEVEl6TURNeE1ERXdNakExT1ZvWERUSTBNRE13T1RFdwpNakExT1Zvd1FqRXJNQ2tHQTFVRUF3d2lLaTVqYkdGemFDNWhjSEJ6TG05d1pXNXphR2xtZEM1bGVHRnRjR3hsCkxtTnZiVEVUTUJFR0ExVUVDZ3dLUTJ4aGMyZ2dTVzVqTGpDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVAKQURDQ0FRb0NnZ0VCQU1QYklqTzIrNFpwN05GZHFIM1c3WTZXb25zMnZWbmJORXBBb2t3OTdIb1Q3R0tyYXA1MQppL0M3N2pyTXdsUnpua2M4MHI1Y3FsWXBLNUd3eml0bEhSWkc5bU5HZzMrKzFRdTk2NjdQV0NRUE1lNzZ2T3VPCnlCdmtvM01wSUI4QkFmZHFJVk45L3BFdWFtdThVZS92U0xTb2hmZk5lSkNyM2oxNzY2MUdFcnVGUjhqRFAxcXEKeDltU09zQ0U0RVJSallJeWE4blFMZE5aMVg4WEYrVGpXekJCdlJ1R3FzS2VZVzNwWEFGamVXaHozcG1aZXovKwphaHljbVM2ckVMU0N1aUIwSU9xZTVsZ0EvcUVoc2xOd2pYSzNvZndicDAxVDJhWFdWenY3K2Z5dURQc3hacktZCnNNMlY3eWx0dlJRZ01YOFZmenEyTkRSeWlnRzU5eWdNQVVFQ0F3RUFBVEFOQmdrcWhraUc5dzBCQVFzRkFBT0MKQVFFQUgxaUUzZmJxY3pQblBITko4WVpyYUtVSUxLd0dDRGRNWllJYlpsK25zSFIyUERSRW5kd3g3T24yengyUwoxTWx1MTYzRjFETlpBVTZZUVp1bGFLN2xrWlpSQllja0xzREcwKzVyb1VxQ2sySU1iaE9FYlE4STNNQi94NytjCkc3NDU0cGZ6YU9nM0hOQlFzSGtzVHN5cUVSQUZranNwQTRBNVhoOUdKMEFrS1d6emZyaGVScGtpOWFzcmhPUjMKUDdJTnR4eDNXbmVrbUJGZzdIYm9pQzZuWXRHUExxMW5sQy84S1lKRk0rYmxpOENHTHVzb2NXS3dzSXkybCtFbQp2UUVLQXMzKzY3SVZ5M0ZtRlFrdFArVzQvQlhuazM0YWZRTUZhZzlnTkdoQVd3elJ6VDNuSmtEN2psWXZmUHZzClNqcUtKU2lONlJRWTBmM2JDNVhNaHlnMFhnPT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
  tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JSUV2UUlCQURBTkJna3Foa2lHOXcwQkFRRUZBQVNDQktjd2dnU2pBZ0VBQW9JQkFRREQyeUl6dHZ1R2FlelIKWGFoOTF1Mk9scUo3TnIxWjJ6UktRS0pNUGV4NkUreGlxMnFlZFl2d3UrNDZ6TUpVYzU1SFBOSytYS3BXS1N1UgpzTTRyWlIwV1J2WmpSb04vdnRVTHZldXV6MWdrRHpIdStyenJqc2diNUtOektTQWZBUUgzYWlGVGZmNlJMbXByCnZGSHY3MGkwcUlYM3pYaVFxOTQ5ZSt1dFJoSzdoVWZJd3o5YXFzZlpranJBaE9CRVVZMkNNbXZKMEMzVFdkVi8KRnhmazQxc3dRYjBiaHFyQ25tRnQ2VndCWTNsb2M5NlptWHMvL21vY25Ka3VxeEMwZ3JvZ2RDRHFudVpZQVA2aApJYkpUY0kxeXQ2SDhHNmROVTltbDFsYzcrL244cmd6N01XYXltTERObGU4cGJiMFVJREYvRlg4NnRqUTBjb29CCnVmY29EQUZCQWdNQkFBRUNnZ0VBRmY3R0dJaTBOcVF1dEZTUVY1R0xuRGZPaDRmZU8va2lKalNjQlhQdTJzYmkKQlRLN0JwQ3M1cHcwWk9ZWjdPSVBKSER3T2ZDdU1IN3ZKYTExZWVvaEdoOWVERWdlL0hteDgxK2cyRUR3NVJ2UAp2OGJvOEl0WWJjbC9rYTlNckM2d3lkaGhaYjhBbDgxZXBqcS8rUEltZUNOMDZCOXJLdFFpWVVWSmNtd3NMbUxYCklhSW4yMEQrMzhRQW9ZZVBoV2NUOUExYVBWTmZ6NXFhOXpsdUtwOUt0bnR5cHdiMnFObmN3UmRSbm5tb0c4bkQKODRjWHJyS1JMZC9JTFBFamVwc2Juc1Q5SHJ3aldIbGJxU1FVc0lhQ29GenI5aWR3eTcrU0hPVWlkTmF3YVhwYQozNDROUnB4Sk5EaEd4ZDhidnJVbTJIMVhLZ2ZIYlBSaWsyU0wvVmRRQVFLQmdRRGdrMTArR0J5N3RBbzdUa2d0Ckh4cDhsQ3lkSUFaYVkzYXUweGRvMXlXNEV0UDVpNjEySk1kYm9TQmhpbGJJQmFpRjRiZ3AzRjA3WFJQeWJBRFgKS1c2aitvTW5SMlRwd1ZsUmJIeW1OT1FYT1hOUEhRWForUFM2bDVjaWs1QlVRVi8vL2NySUFvS3pIUHpOckl3OQpZMGZoWmNrZHRpL0pIZVJZandnWCsvb3I2UUtCZ1FEZlF2ME1ld01mQ3JmWVRCdlVGZldncm9pbU9PWEFhV2M4ClVBVVB2MXdQYjVSbkY5eWdDQjRQL2l5QVlwOWl1aHBodDM3NjdVcGVsL3pCQitmNzZ0bHZaNWIySzBDWHNwaUIKdGNSSnU2ZWZLdEFqZGNqQ3BRM3hpelpTNjNFSHJIWDREY2s4QlhVcG96Q3R5N1BPeXZobDRwMFdyL2gwWW1OYgplU0FWcFViTG1RS0JnUURLTHFIUmwyKzI1WDRZcW45OGIvWXVsbEFjSFlyYXNaVldDNkdWdDZ5enJlKzlTSzBnCklqaUJHK3pGSkFEQkQ2Y0s4WTRWMGRqMTZ2UmNXalBmZ2VPa0taTU9OODU0VEtRWEZDNmNqQjJWY3htRzdrQW8KWDJRazRQa21IZWZna3dMVXV5NW5KeXQ0Q2U3blZDTGwyWTRMTk5IOXQ5b0puS25KdU91MmZCcGNrUUtCZ0F6OApkSU9aVkNFbUduTjJXZGdJUHZWTnNaMFppaU9hL2VwQUxVc3hNa1dqazlvN1JSWDU0dVhEUHd0b3NTU285b2ZnCmlINUg5eDl4Yjc0Nm0zL0h0VVlKbkhwTkljQ3hIclhNd05JWkhETGg1cUZwWkhnTjZiVzNCejNqZS91YVNISloKT3U5RzBmM09CRExYdW1tNDNLSHdnSHFsV2FwTFhzUWZVNEp1enFOaEFvR0FYRGhoaFBZTWt3TFhzQUdxSmlpOApUcnd3cGExN21vbzJoQ2FncFRsemdaR281bjZFandoM1ZoN0JaQ0hJc0FmY3ZoUUZ2OE1UZXVGQzBvNUZGU3gwCjN0MHpKQWdrWFBXYnhXQU9mU3FZc1NGR0tyVHFuNngzcTRWQXVyZ09Qa2pFd3VIUkFMajJyMFZVWUg4OWRab0QKWDBGcUM4SUNRWjRlbDFVd0c5bXAvaEE9Ci0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS0K
kind: Secret
metadata:
  name: wildcard-certs
  namespace: istio-system
type: kubernetes.io/tls
---
EOF
