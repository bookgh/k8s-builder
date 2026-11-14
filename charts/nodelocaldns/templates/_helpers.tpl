{{- define "nodelocaldns.name" -}}
node-local-dns
{{- end }}

{{- define "nodelocaldns.fullname" -}}
{{- default "node-local-dns" .Values.serviceAccount.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nodelocaldns.labels" -}}
k8s-app: node-local-dns
kubernetes.io/cluster-service: "true"
addonmanager.kubernetes.io/mode: Reconcile
app.kubernetes.io/name: {{ include "nodelocaldns.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "nodelocaldns.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- .Values.serviceAccount.name | default "node-local-dns" }}
{{- else }}
{{- .Values.serviceAccount.name | default "default" }}
{{- end }}
{{- end }}
