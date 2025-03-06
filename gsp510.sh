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

# Définir les variables pour le déploiement
CLUSTER_NAME="hello-world-wmn7"
ZONE="us-west1-c"
NAMESPACE="gmp-m4xd"
SERVICE_NAME="helloweb-service-0tpk"
INTERVAL="45s"
REPO_NAME="demo-repo"

#----------------------------------------------------Début--------------------------------------------------#

echo "${BG_MAGENTA}${BOLD}Démarrage de l'exécution...${RESET}"

# Configurer la zone de calcul
gcloud config set compute/zone $ZONE

# Créer un cluster GKE avec la version spécifiée
echo "${YELLOW}${BOLD}Création du cluster GKE $CLUSTER_NAME...${RESET}"
gcloud container clusters create $CLUSTER_NAME \
  --release-channel regular \
  --cluster-version latest \
  --num-nodes 3 \
  --min-nodes 2 \
  --max-nodes 6 \
  --enable-autoscaling --no-enable-ip-alias

# Mise à jour du cluster GKE avec Prometheus géré activé
echo "${YELLOW}${BOLD}Activation de Prometheus géré sur le cluster...${RESET}"
gcloud container clusters update $CLUSTER_NAME --enable-managed-prometheus --zone $ZONE

# Créer le namespace
echo "${YELLOW}${BOLD}Création du namespace $NAMESPACE...${RESET}"
kubectl create ns $NAMESPACE

# Déploiement de l'application Prometheus
echo "${YELLOW}${BOLD}Déploiement de l'application Prometheus...${RESET}"
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
echo "${YELLOW}${BOLD}Configuration de la surveillance des pods...${RESET}"
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
echo "${YELLOW}${BOLD}Téléchargement et déploiement de l'application Hello App...${RESET}"
gsutil cp -r gs://spls/gsp510/hello-app/ .

export PROJECT_ID=$(gcloud config get-value project)
export REGION="${ZONE%-*}"

cd ~/hello-app
gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE

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

echo "${YELLOW}${BOLD}Déploiement initial de l'application Hello App...${RESET}"
kubectl -n $NAMESPACE apply -f manifests/helloweb-deployment.yaml

# Création d'une métrique de log
echo "${YELLOW}${BOLD}Création d'une métrique de log pour les erreurs d'image des pods...${RESET}"
gcloud logging metrics create pod-image-errors \
  --description="Alertes sur les erreurs d'image des pods" \
  --log-filter="resource.type=\"k8s_pod\" severity=WARNING"

# Création d'une politique d'alerte
echo "${YELLOW}${BOLD}Création d'une politique d'alerte...${RESET}"
cat > awesome.json <<EOF_END
{
  "displayName": "Pod Error Alert",
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

# Mise à jour de l'image de l'application Hello
echo "${YELLOW}${BOLD}Mise à jour de l'application avec la version 2.0.0...${RESET}"
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

# Suppression du déploiement helloweb existant
echo "${YELLOW}${BOLD}Suppression du déploiement helloweb existant...${RESET}"
kubectl delete deployments helloweb -n $NAMESPACE

# Redéploiement de l'application avec l'image correcte
echo "${YELLOW}${BOLD}Redéploiement de l'application avec l'image correcte...${RESET}"
kubectl -n $NAMESPACE apply -f manifests/helloweb-deployment.yaml

# Construction et déploiement de l'image Docker
echo "${YELLOW}${BOLD}Construction et déploiement de l'image Docker v2...${RESET}"
export PROJECT_ID=$(gcloud config get-value project)
export REGION="${ZONE%-*}"
cd ~/hello-app/

gcloud auth configure-docker $REGION-docker.pkg.dev --quiet
docker build -t $REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/hello-app:v2 .
docker push $REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/hello-app:v2

# Mise à jour du déploiement avec la nouvelle image
echo "${YELLOW}${BOLD}Mise à jour du déploiement avec la nouvelle image v2...${RESET}"
kubectl set image deployment/helloweb -n $NAMESPACE hello-app=$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/hello-app:v2

# Exposer le service sur le port 8080
echo "${YELLOW}${BOLD}Exposition du service sur le port 8080...${RESET}"
kubectl expose deployment helloweb -n $NAMESPACE --name=$SERVICE_NAME --type=LoadBalancer --port 8080 --target-port 8080

# Attendre que le service soit disponible
echo "${YELLOW}${BOLD}En attente de l'attribution d'une adresse IP externe au service...${RESET}"
while [ -z "$(kubectl get service $SERVICE_NAME -n $NAMESPACE --template='{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}')" ]; do
  echo "En attente de l'adresse IP externe..."
  sleep 10
done

# Afficher l'adresse IP externe du service
EXTERNAL_IP=$(kubectl get service $SERVICE_NAME -n $NAMESPACE --template='{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}')
echo "${GREEN}${BOLD}Service déployé avec succès à l'adresse: http://$EXTERNAL_IP:8080${RESET}"

# Vérifier la connectivité
echo "${YELLOW}${BOLD}Vérification de la connectivité...${RESET}"
curl -s http://$EXTERNAL_IP:8080

# Vérifier les déploiements
echo -e "\n${YELLOW}${BOLD}Liste des déploiements:${RESET}"
kubectl get deployments -n $NAMESPACE

# Vérifier les pods
echo -e "\n${YELLOW}${BOLD}Liste des pods:${RESET}"
kubectl get pods -n $NAMESPACE

# Vérifier les services
echo -e "\n${YELLOW}${BOLD}Liste des services:${RESET}"
kubectl get services -n $NAMESPACE

# Finaliser
echo "${BG_GREEN}${BOLD}Félicitations pour avoir complété le déploiement !!!${RESET}"
echo "${CYAN}Vous avez réussi à:${RESET}"
echo "${CYAN}- Créer un cluster GKE avec autoscaling${RESET}"
echo "${CYAN}- Activer Prometheus géré${RESET}"
echo "${CYAN}- Déployer une application de test Prometheus${RESET}"
echo "${CYAN}- Configurer la surveillance des pods${RESET}"
echo "${CYAN}- Créer et déployer une application Hello App${RESET}"
echo "${CYAN}- Configurer des métriques de log et des alertes${RESET}"
echo "${CYAN}- Construire et déployer une image Docker v2${RESET}"
echo "${CYAN}- Exposer l'application via un service LoadBalancer${RESET}"

#-----------------------------------------------------Fin----------------------------------------------------------
