#!/bin/bash
# Définir les variables de couleurs
BLACK=`tput setaf 0`
RED=`tput setaf 1`
GREEN=`tput setaf 2`
YELLOW=`tput setaf 3`
BLUE=`tput setaf 4`
MAGENTA=`tput setaf 5`
CYAN=`tput setaf 6`
WHITE=`tput setaf 7`

BG_BLACK=`tput setab 0`
BG_RED=`tput setab 1`
BG_GREEN=`tput setab 2`
BG_YELLOW=`tput setab 3`
BG_BLUE=`tput setab 4`
BG_MAGENTA=`tput setab 5`
BG_CYAN=`tput setab 6`
BG_WHITE=`tput setab 7`

BOLD=`tput bold`
RESET=`tput sgr0`

#----------------------------------------------------Début--------------------------------------------------#

echo "${BG_MAGENTA}${BOLD}Démarrage de l'exécution...${RESET}"

# Configurer la zone de calcul
gcloud config set compute/zone $ZONE

# Créer un cluster GKE avec la version spécifiée
gcloud container clusters create $CLUSTER_NAME \
  --release-channel regular \
  --cluster-version 1.31.5-gke.1169000 \
  --num-nodes 3 \
  --min-nodes 2 \
  --max-nodes 6 \
  --enable-autoscaling --no-enable-ip-alias

# Mise à jour du cluster GKE avec Prometheus géré activé
gcloud container clusters update $CLUSTER_NAME --enable-managed-prometheus --zone $ZONE

# Créer le namespace
kubectl create ns $NAMESPACE

# Déploiement de l'application Prometheus
gsutil cp gs://spls/gsp510/prometheus-app.yaml .
cat > prometheus-app.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-test
  labels:
    app: prometheus-test
spec:
  selector:
    matchLabels:
      app: prometheus-test
  replicas: 3
  template:
    metadata:
      labels:
        app: prometheus-test
    spec:
      nodeSelector:
        kubernetes.io/os: linux
        kubernetes.io/arch: amd64
      containers:
      - image: nilebox/prometheus-example-app:latest
        name: prometheus-test
        ports:
        - name: metrics
          containerPort: 1234
        command:
        - "/main"
        - "--process-metrics"
        - "--go-metrics"
EOF

kubectl -n $NAMESPACE apply -f prometheus-app.yaml

# Déploiement de la configuration de surveillance des pods
gsutil cp gs://spls/gsp510/pod-monitoring.yaml .
cat > pod-monitoring.yaml <<EOF
apiVersion: monitoring.googleapis.com/v1alpha1
kind: PodMonitoring
metadata:
  name: prometheus-test
  labels:
    app.kubernetes.io/name: prometheus-test
spec:
  selector:
    matchLabels:
      app: prometheus-test
  endpoints:
  - port: metrics
    interval: $INTERVAL
EOF

kubectl -n $NAMESPACE apply -f pod-monitoring.yaml

# Déploiement de l'application "Hello App" dans GKE
gsutil cp -r gs://spls/gsp510/hello-app/ .

export PROJECT_ID=$(gcloud config get-value project)
export REGION="${ZONE%-*}"

cd ~/hello-app
gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE
kubectl -n $NAMESPACE apply -f manifests/helloweb-deployment.yaml

# Déploiement de l'application Web
cd manifests/
cat > helloweb-deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloweb
  labels:
    app: hello
spec:
  selector:
    matchLabels:
      app: hello
      tier: web
  template:
    metadata:
      labels:
        app: hello
        tier: web
    spec:
      containers:
      - name: hello-app
        image: us-docker.pkg.dev/google-samples/containers/gke/hello-app:1.0
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 200m
EOF

cd ..

kubectl delete deployments helloweb -n $NAMESPACE
kubectl -n $NAMESPACE apply -f manifests/helloweb-deployment.yaml

# Mise à jour de l'image de l'application Hello
cat > main.go <<EOF
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", hello)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Server listening on port %s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func hello(w http.ResponseWriter, r *http.Request) {
	log.Printf("Serving request: %s", r.URL.Path)
	host, _ := os.Hostname()
	fmt.Fprintf(w, "Hello, world!\n")
	fmt.Fprintf(w, "Version: 2.0.0\n")
	fmt.Fprintf(w, "Hostname: %s\n", host)
}
EOF

# Construction et déploiement de l'image Docker
export PROJECT_ID=$(gcloud config get-value project)
export REGION="${ZONE%-*}"
cd ~/hello-app/

gcloud auth configure-docker $REGION-docker.pkg.dev --quiet
docker build -t $REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/hello-app:v2 .
docker push $REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/hello-app:v2

kubectl set image deployment/helloweb -n $NAMESPACE hello-app=$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/hello-app:v2

# Exposer le service sur le port 8080
kubectl expose deployment helloweb -n $NAMESPACE --name=$SERVICE_NAME --type=LoadBalancer --port 8080 --target-port 8080

# Appliquer la configuration de surveillance
kubectl -n $NAMESPACE apply -f pod-monitoring.yaml

# Création d'une métrique de log
gcloud logging metrics create pod-image-errors \
  --description="Alertes sur les erreurs d'image des pods" \
  --log-filter="resource.type=\"k8s_pod\" severity=WARNING"

# Création d'une politique d'alerte
cat > awesome.json <<EOF_END
{
  "displayName": "Alerte Erreur Pod",
  "conditions": [
    {
      "displayName": "Kubernetes Pod - logging/user/pod-image-errors",
      "conditionThreshold": {
        "filter": "resource.type = \"k8s_pod\" AND metric.type = \"logging.googleapis.com/user/pod-image-errors\"",
        "aggregations": [
          {
            "alignmentPeriod": "600s",
            "crossSeriesReducer": "REDUCE_SUM",
            "perSeriesAligner": "ALIGN_COUNT"
          }
        ],
        "comparison": "COMPARISON_GT",
        "duration": "0s",
        "trigger": {
          "count": 1
        },
        "thresholdValue": 0
      }
    }
  ],
  "alertStrategy": {
    "autoClose": "604800s"
  },
  "combiner": "OR",
  "enabled": true
}
EOF_END

# Créer la politique d'alerte
gcloud alpha monitoring policies create --policy-from-file="awesome.json"

# Finaliser
echo "${BG_RED}${BOLD}Félicitations pour avoir complété le déploiement !!!${RESET}"

#-----------------------------------------------------Fin----------------------------------------------------------
