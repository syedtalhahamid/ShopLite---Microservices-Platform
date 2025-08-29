0) Prerequisites (on your laptop / control machine / Jenkins agent)

Make sure these are installed and accessible in your shell (Linux/macOS recommended; on Windows use WSL/Git Bash):


git        # git CLI
docker     # docker engine
docker-compose
aws        # AWS CLI v2
terraform  # appropriate version
kubectl
helm
ansible

Configure AWS CLI (needed for Terraform, ECR, EKS):


aws configure
# or export environment variables:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1





1) Quick local smoke test with Docker Compose

Goal: verify microservices build & run locally.

From repo root:

# build and run
docker-compose up --build -d

# list containers
docker-compose ps

# check logs for one service (auth)
docker-compose logs -f auth

# verify endpoint
curl http://localhost:5001/    # auth (or ports defined in your docker-compose)
curl http://localhost:5001/metrics


If something fails:

* `docker-compose up` will show build errors — fix Dockerfile or missing files.
* If ports conflict on Windows, stop services and try different host ports in `docker-compose.yaml`.

When OK, stop local compose (or keep running for testing):


docker-compose down



2) Push repo to Git (GitHub / GitLab)

If not yet pushed:


git add .
git commit -m "initial: microservices + infra + k8s + jenkinsfile"
git remote add origin https://github.com/<your-org>/<repo>.git
git push -u origin main


Verify repo is visible in your Git host.




3) Provision cloud infra with Terraform (ECR + EKS etc.)

Go to your terraform folder:


cd infra/terraform
terraform init

# optional: inspect variables in variables.tf and set terraform.tfvars if needed
terraform plan -out=tfplan

# when ready:
terraform apply -auto-approve



What to look for:

* Terraform should create ECR repositories and EKS cluster (and VPC & subnets if configured).
* `terraform output` will print useful values (ECR repo URLs, EKS cluster name, etc.)



terraform output


If `apply` fails:

* Check AWS credentials / IAM permissions.
* Inspect cloud console for resource quotas (VPC, subnets).
* Fix errors & re-run `terraform apply`.




4) Configure `kubectl` to talk to the EKS cluster

If Terraform outputs kubeconfig or cluster name, use AWS CLI:


aws eks update-kubeconfig --region <REGION> --name <CLUSTER_NAME>
kubectl get nodes
kubectl get ns


If `kubectl get nodes` returns nodes ready → good.
If it errors:

* Ensure your IAM user / role has `eks:DescribeCluster`.
* Confirm Terraform created node groups and nodes are in `Ready` state.




# 5) Create ECR login & push one image (manual test)

You can push images manually or let Jenkins build & push. Test one manually to confirm permissions:

Set vars:


AWS_ACCOUNT_ID=<your-account-id>
REGION=<your-region>
REPO_NAME=shoplite-auth   # or the repository name Terraform created

# Build image
docker build -t ${REPO_NAME}:latest microservices/auth

# Tag for ECR
ECR_URI=${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}
docker tag ${REPO_NAME}:latest ${ECR_URI}:latest

# Login to ECR and push
aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
docker push ${ECR_URI}:latest


If push fails:

* Make sure the ECR repo exists (Terraform should create it) or create it:


  aws ecr create-repository --repository-name ${REPO_NAME} --region ${REGION}


* Check IAM permission to push to ECR.




# 6) Update k8s manifests to use the pushed images (or use kustomize/templating)

If your `k8s/*-deployment.yaml` files contain placeholders like `<ECR_REPO>/auth:latest`, replace them:

Option A — edit YAML files and set image to `${ECR_URI}:latest`

Option B — use `kubectl set image`:


kubectl -n shoplite set image deployment/auth auth=${ECR_URI}:latest
kubectl -n shoplite rollout status deployment/auth



Apply manifests (namespace first if not applied):


kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/auth-deployment.yaml
kubectl apply -f k8s/product-deployment.yaml
kubectl apply -f k8s/order-deployment.yaml
kubectl get pods -n shoplite


Troubleshoot pods:


kubectl get pods -n shoplite
kubectl describe pod <pod-name> -n shoplite
kubectl logs <pod-name> -n shoplite





7) Bootstrap Jenkins with Ansible (or manually)

If you want Jenkins installed automatically, run the Ansible playbook:

Set inventory (e.g. `infra/ansible/inventory.ini`) to contain the EC2 IP of Jenkins host:


[jenkins]
ec2-xx-yy-zz.compute-1.amazonaws.com ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/yourkey.pem


Run playbook:


cd infra/ansible
ansible-playbook -i inventory.ini playbooks/jenkins-setup.yml


What the playbook should do:

* install docker & docker-compose
* install jenkins and java
* install kubectl on the Jenkins host

After playbook completes, open Jenkins UI: `http://<JENKINS_HOST_IP>:8080`

If Ansible fails:

* SSH connectivity or private key issue (check `ansible -m ping -i inventory.ini all`).
* Missing `become` or privilege errors; rerun with proper ssh user.




# 8) Configure Jenkins (manual steps in UI)

Login to Jenkins and:

1. Install recommended plugins (or at least):

   * Pipeline
   * Git
   * Docker Pipeline
   * Kubernetes CLI Plugin (kubectl)
   * AWS Credentials / Amazon ECR plugin (optional)
   * Credentials Binding

2. Add credentials:

   * AWS credentials (access key id + secret) — or configure IAM role if Jenkins runs on AWS EC2 with appropriate role.
   * DockerHub / Registry credentials (if needed).
   * Kubeconfig secret or configure `kubectl` on the Jenkins agent (preferred). Option: store kubeconfig in Jenkins Credentials as a `Secret file` and write it to `~/.kube/config` in pipeline.

3. Ensure Jenkins user can run Docker (if you build images on Jenkins):

   * On the Jenkins host: `sudo usermod -aG docker jenkins` and restart Jenkins service.




9) Create a Jenkins pipeline job (Multibranch or Pipeline) that uses `jenkins/Jenkinsfile`

Option A — Multibranch Pipeline: point to your Git repo → Jenkins will read Jenkinsfile and create branches.

Option B — Pipeline job:

* Create Pipeline → enable `Pipeline script from SCM` → point to your Git repo and branch.

Run the pipeline. Typical stages (from our Jenkinsfile):

* Checkout code
* Build Docker images
* Login to ECR
* Tag & push images to ECR
* `kubectl apply` or `kubectl set image` to deploy to cluster

Troubleshoot:

* If `docker build` fails: check docker permissions and environment.
* If `aws ecr get-login-password` fails: check AWS credentials configured in Jenkins (Credentials plugin).
* If `kubectl` step fails: ensure `kubeconfig` is available to the Jenkins agent (either via environment or mounted secret) and that the Jenkins agent has `kubectl` binary.





# 10) Verify CI/CD end-to-end

After pipeline runs successfully:



# check k8s deployments and pods
kubectl get deployments -n shoplite
kubectl get pods -n shoplite

# see rollout status
kubectl rollout status deployment/auth -n shoplite

# get service info
kubectl get svc -n shoplite



Access app:

* If you exposed a LoadBalancer service, get the external IP:

  
  kubectl get svc -n shoplite
  
* Otherwise use `kubectl port-forward` to test:

  
  kubectl port-forward svc/auth 5001:5000 -n shoplite
  curl http://localhost:5001/
  





11) Install Monitoring (Prometheus + Grafana) via Helm

Recommended: use `kube-prometheus-stack` (Prometheus Operator + Grafana).


helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# install kube-prometheus-stack (creates prometheus + grafana + serviceMonitors)
helm install monitoring prometheus-community/kube-prometheus-stack -n shoplite --create-namespace


Verify:


kubectl get pods -n shoplite


Port-forward Grafana UI:


kubectl port-forward svc/monitoring-grafana 3000:80 -n shoplite
#then open http://localhost:3000


Get Grafana admin password (example — depends on release name):


kubectl get secret -n shoplite monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo


Add Prometheus as data source (most Helm charts do this automatically). Create dashboards to show your `/metrics` scraped from microservices.




12) Common troubleshooting summary

* **Docker permission denied**: add your user/jenkins user to `docker` group and restart session/service.
* **ECR push denied**: confirm `aws ecr get-login-password` login and correct repo name.
* **kubectl: no context**: run `aws eks update-kubeconfig` or use kubeconfig from Terraform output.
* **Pods CrashLoopBackOff**: `kubectl logs` and `kubectl describe pod` to find missing env vars, DB connection errors, missing image, or wrong command.
* **Jenkins pipeline fails at AWS commands**: ensure Jenkins credentials are set and pipeline uses them (Credentials Binding).
* **Prometheus not scraping**: ensure your services expose `/metrics` and Prometheus has a ServiceMonitor or scrape config for those services.





# 13) Cleanup (when you want to tear down)

Local:

docker-compose down


Kubernetes:


kubectl delete -f k8s/ --ignore-not-found
kubectl delete namespace shoplite


Terraform infra (destructive):


cd infra/terraform
terraform destroy -auto-approve




14) Next steps / Improvements (pick any)

* Use image tags with commit SHA instead of `latest`.
* Add Helm charts for your microservices and use Helm in Jenkins to `helm upgrade --install`.
* Use IRSA (IAM roles for service accounts) for EKS and limit IAM privileges.
* Add Prometheus `ServiceMonitor` resources and Grafana dashboards for each microservice metric.
* Add centralized logging (Filebeat/ELK) on k8s.
