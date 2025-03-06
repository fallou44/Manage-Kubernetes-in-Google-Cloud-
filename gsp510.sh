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

# Définir les variables d'environnement
export REPO_NAME="demo-repo"
export CLUSTER_NAME="hello-world-y66u"
export ZONE="us-east1-d"
export NAMESPACE="gmp-rgmm"
export INTERVAL="30s"
export SERVICE_NAME="helloweb-service-os77"

# Définir le projet Google Cloud
export PROJECT_ID=$(gcloud config get-value project)
gcloud config set project $PROJECT_ID

# Configurer la zone de calcul
gcloud config set compute/zone $ZONE

# Créer un cluster GKE avec la version spécifiée
echo "${BG_BLUE}${BOLD}Création du cluster GKE...${RESET}"
gcloud container clusters create $CLUSTER_NAME \
  --release-channel regular \
  --cluster-version "1.27.8-gke.1067000" \
  --num-nodes 3 \
  --min-nodes 2 \
  --max-nodes 6 \
  --enable-autoscaling --no-enable-ip-alias

# Configurer kubectl pour le cluster GKE
gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE

# Mise à jour du cluster GKE avec Prometheus géré activé
echo "${BG_BLUE}${BOLD}Activation de Prometheus géré...${RESET}"
gcloud container clusters update $CLUSTER_NAME --enable-managed-prometheus --zone $ZONE

# Créer le namespace
echo "${BG_BLUE}${BOLD}Création du namespace...${RESET}"
kubectl create ns $NAMESPACE

# Déploiement de l'application Prometheus
echo "${BG_BLUE}${BOLD}Déploiement de l'application Prometheus...${RESET}"
gsutil cp gs://spls/gsp510/prometheus-app.yaml .
sed -i 's/<todo>/nilebox\/prometheus-example-app:latest/g' prometheus-app.yaml
kubectl -n $NAMESPACE apply -f prometheus-app.yaml

# Déploiement de la configuration de surveillance des pods
echo "${BG_BLUE}${BOLD}Déploiement de la configuration de surveillance des pods...${RESET}"
gsutil cp gs://spls/gsp510/pod-monitoring.yaml .
sed -i 's/<todo>/prometheus-test/g' pod-monitoring.yaml
kubectl -n $NAMESPACE apply -f pod-monitoring.yaml

# Déploiement de l'application "Hello App" dans GKE
echo "${BG_BLUE}${BOLD}Déploiement de l'application Hello App...${RESET}"
gsutil cp -r gs://spls/gsp510/hello-app/ .

cd ~/hello-app
kubectl -n $NAMESPACE apply -f manifests/helloweb-deployment.yaml

# Mise à jour de l'image de l'application Hello
echo "${BG_BLUE}${BOLD}Mise à jour de l'image de l'application Hello...${RESET}"
sed -i 's/<todo>/us-docker.pkg.dev\/google-samples\/containers\/gke\/hello-app:1.0/g' manifests/helloweb-deployment.yaml
kubectl delete deployments helloweb -n $NAMESPACE
kubectl -n $NAMESPACE apply -f manifests/helloweb-deployment.yaml

# Mise à jour du code de l'application Hello
echo "${BG_BLUE}${BOLD}Mise à jour du code de l'application Hello...${RESET}"
sed -i 's/Version: 1.0.0/Version: 2.0.0/g' main.go

# Construction et déploiement de l'image Docker
echo "${BG_BLUE}${BOLD}Construction et déploiement de l'image Docker...${RESET}"
gcloud auth configure-docker $REGION-docker.pkg.dev --quiet
docker build -t $REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/hello-app:v2 .
docker push $REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/hello-app:v2

kubectl set image deployment/helloweb -n $NAMESPACE hello-app=$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/hello-app:v2

# Exposer le service sur le port 8080
echo "${BG_BLUE}${BOLD}Exposition du service sur le port 8080...${RESET}"
kubectl expose deployment helloweb -n $NAMESPACE --name=$SERVICE_NAME --type=LoadBalancer --port 8080 --target-port 8080

# Création d'une métrique de log
echo "${BG_BLUE}${BOLD}Création d'une métrique de log...${RESET}"
gcloud logging metrics create pod-image-errors \
  --description="Alertes sur les erreurs d'image des pods" \
  --log-filter="resource.type=\"k8s_pod\" severity=WARNING"

# Création d'une politique d'alerte
echo "${BG_BLUE}${BOLD}Création d'une politique d'alerte...${RESET}"
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
  "enabled": true,
  "projectId": "$PROJECT_ID"
}
EOF_END

# Créer la politique d'alerte
gcloud alpha monitoring policies create --policy-from-file="awesome.json"

# Finaliser
echo "${BG_RED}${BOLD}Félicitations pour avoir complété le déploiement !!!${RESET}"

#-----------------------------------------------------Fin----------------------------------------------------------
