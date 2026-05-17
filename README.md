# Fraud Detector — Infraestructura como Código

Sistema de detección de fraude en tiempo real desplegado en AWS mediante Terraform.
Transacciones financieras ingresan desde un sitio on-premise simulado, son procesadas por un motor de scoring corriendo en Fargate, y los resultados quedan disponibles en un dashboard web.

La arquitectura detallada está en [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Arquitectura

```
On-Prem VPC 192.168.0.0/16              AWS VPC 10.0.0.0/16 — solo subnets privadas
┌──────────────────────┐                ┌────────────────────────────────────────┐
│    EC2 strongSwan    │                │                                        │
│  (router IPsec/BGP)  │═══════VPN══════╪══▶ VGW                                 │
└──────────────────────┘  2 túneles     │                                        │
          │                             │  ┌──────────────────────┐              │
          │ SQS sobre VPN               │  │ ECS Fargate (2 tasks)│              │
          └────────────────────────────▶│  │    scoring engine    │◀── ECR image │
                                        │  └──────────┬───────────┘              │
                                        │             │ Publish to SNS           │
                                        │             ▼                          │
                                        │  ┌──────────────────────┐              │
                                        │  │      SNS Topic       │              │
                                        │  └──────────┬───────────┘              │
                                        │             │ SQS Subscribe to SNS     │
                                        │             ▼                          │
                                        │  ┌───────────────────────┐             │
                                        │  │   SQS Queue results   │             │
                                        │  └──────────┬────────────┘             │
                                        │             │ Send message to Lambda   │
                                        │             ▼                          │
                                        │  ┌───────────────────────┐             │
                                        │  │ Lambda results-writer │             │
                                        │  └──────────┬────────────┘             │
                                        │             │ Write message to RDS     │
                                        │             ▼                          │
                                        │  ┌──────────────────────┐              │
                                        │  │      RDS Proxy       │              │
                                        │  └──────────┬───────────┘              │
                                        │             │ Query RDS                │
                                        │             ▼                          │
                                        │  ┌──────────────────────┐              │
                                        │  │    RDS PostgreSQL    │              │
                                        │  │    (fraud_results)   │              │
                                        │  └──────────┬───────────┘              │
                                        │             │ Serve API                │
                                        │  ┌──────────┴───────────┐              │
                                        │  │     Lambda API       │              │
                                        │  └──────────┬───────────┘              │
                                        │             │                          │
                                        └─────────────┴──────────────────────────┘
                                                      │
                                           ┌──────────┴──────────┐
                                           │   API Gateway HTTP  │
                                           └──────────┬──────────┘
                                                      │
                                           ┌──────────┴──────────┐
                                           │    S3 Dashboard     │
                                           │  (sitio estático)   │
                                           └─────────────────────┘
```

**Flujo de datos:**

1. Un productor on-prem envía una transacción JSON al SQS de ingesta a través del túnel VPN, este JSON contiene información de la transacción y el usuario.
2. Fargate consume el mensaje, consulta el perfil del usuario en DynamoDB y calcula el fraud score
3. El resultado se publica en SNS, que lo distribuye a una cola SQS de resultados
4. La Lambda `results-writer` toma el mensaje de SQS y persiste el resultado en RDS vía RDS Proxy
5. La Lambda `api` expone esos datos a través de API Gateway
6. El dashboard (S3 website) consume la API y muestra el estado en tiempo real

---

## Módulos

### `modules/network`

Provisiona la VPC privada que aloja toda la infraestructura. No tiene NAT Gateway ni Internet Gateway. Todo el egress a servicios AWS fluye por VPC Endpoints, reduciendo costos y superficie de ataque.

**Recursos clave:**
- [`module "vpc"`](modules/network/main.tf#L22) (`terraform-aws-modules/vpc/aws`): VPC `10.0.0.0/16` con 2 subnets privadas en distintas AZs; Virtual Private Gateway (VGW) para la VPN site-to-site vía [`enable_vpn_gateway`](modules/network/main.tf#L38)
- **Gateway VPC Endpoints** (S3, DynamoDB): [`aws_vpc_endpoint.gateway`](modules/network/main.tf#L83)
- **Interface VPC Endpoints** (SQS, ECR API, ECR DKR, CloudWatch Logs, SNS, Secrets Manager): [`aws_vpc_endpoint.interface`](modules/network/main.tf#L96)

**Módulo externo**: el pin `~> 5.13` está en [`modules/network/main.tf`](modules/network/main.tf#L22); los VPC Endpoints propios son los recursos enlazados arriba.

---

### `modules/queue`

Cola SQS de ingesta de transacciones con Dead Letter Queue. Solo acepta mensajes cuya IP de origen esté dentro del CIDR on-prem (`192.168.0.0/16`), implementado mediante una política `Deny` con la condición `aws:VpcSourceIp`. Esto garantiza que únicamente el sitio on-prem puede producir mensajes.

**Recursos:** [`aws_sqs_queue.main`](modules/queue/main.tf#L31) + [`aws_sqs_queue.dlq`](modules/queue/main.tf#L10), [`aws_sqs_queue_redrive_allow_policy.dlq`](modules/queue/main.tf#L22), [`aws_sqs_queue_policy.main`](modules/queue/main.tf#L116) y [`aws_sqs_queue_policy.dlq`](modules/queue/main.tf#L161)

---

### `modules/data_store`

Toda la capa de persistencia del sistema en un único módulo:

- **DynamoDB** `itba-tp-fraud-user-behavior`: [`aws_dynamodb_table.user_behavior`](modules/data_store/main.tf#L13) — perfiles de comportamiento de usuarios. Clave de partición `user_id`. Consultado por Fargate durante el scoring para enriquecer la decisión con historial del usuario.
- **RDS PostgreSQL 17.4** `itba-tp-fraud-results-db`: [`aws_db_instance.results`](modules/data_store/main.tf#L118) almacena los resultados de scoring (`transaction_id`, `fraud_score`, `is_fraud`, `decision`, `processed_at`, etc.). Acceso exclusivo desde dentro de la VPC a través del RDS Proxy.
- **Secrets Manager**: [`aws_secretsmanager_secret.db_credentials`](modules/data_store/main.tf#L161) y [`aws_secretsmanager_secret_version`](modules/data_store/main.tf#L172) — credenciales RDS en JSON para autenticación del proxy.
- **RDS Proxy**: [`aws_db_proxy.results`](modules/data_store/main.tf#L194), [`aws_db_proxy_default_target_group`](modules/data_store/main.tf#L216), [`aws_db_proxy_target`](modules/data_store/main.tf#L230) — pool entre Lambdas y RDS; mitiga el agotamiento de conexiones en `db.t3.micro` (~50 conexiones máx).
- **Security Group del proxy**: [`aws_security_group.proxy`](modules/data_store/main.tf#L182); las reglas cruzadas con Lambdas/RDS están en la raíz — [`main.tf`](main.tf#L169) (`proxy_to_rds`, `rds_from_proxy`, `writer_lambda_to_proxy`, `api_lambda_to_proxy`, etc.) para evitar dependencias circulares entre módulos.

---

### `modules/compute`

Motor de scoring corriendo en ECS Fargate. Lee transacciones de SQS, consulta DynamoDB, aplica el modelo ML (con fallback a reglas si el modelo no está disponible), y publica el resultado en SNS.

**Recursos:** [`aws_ecr_repository.app`](modules/compute/main.tf#L48), [`aws_ecs_cluster.main`](modules/compute/main.tf#L78) (Container Insights en el cluster), [`aws_ecs_task_definition.app`](modules/compute/main.tf#L142), [`aws_ecs_service.app`](modules/compute/main.tf#L165), Application Auto Scaling ([`aws_appautoscaling_target`](modules/compute/main.tf#L194), [`aws_appautoscaling_policy`](modules/compute/main.tf#L204)).

**Auto Scaling**: política de target tracking con métrica compuesta `messages_per_task = ApproximateNumberOfMessagesVisible / max(RunningTaskCount, 1)`. Si el backlog supera 10 mensajes por task, escala horizontalmente hasta 10 tasks.

**Variables de entorno del contenedor**: `QUEUE_URL`, `SNS_TOPIC_ARN`, `DYNAMODB_TABLE_NAME`, `AWS_REGION`, `S3_AUDIT_BUCKET`.

---

### `modules/notification`

Topic SNS que actúa como hub de distribución de resultados. Cuando el fraud processor publica un resultado, SNS lo entrega simultáneamente a:
- La cola SQS de resultados (para persistencia en RDS) — suscripción [`aws_sns_topic_subscription.results_sqs`](modules/results_writer/main.tf#L119) en `modules/results_writer`
- Una suscripción de email opcional, filtrada a `is_fraud = true` (usando `filter_policy_scope = "MessageBody"`)

**Recursos:** [`aws_sns_topic.results`](modules/notification/main.tf#L9), [`aws_sns_topic_policy.results`](modules/notification/main.tf#L65), [`aws_sns_topic_subscription.email_alert`](modules/notification/main.tf#L70)

---

### `modules/results_writer`

Pipeline SNS → SQS → Lambda para persistir resultados en RDS.

**Recursos:**
- SQS `itba-tp-fraud-results-events` + DLQ: [`aws_sqs_queue.results`](modules/results_writer/main.tf#L35) + [`aws_sqs_queue.results_dlq`](modules/results_writer/main.tf#L14) ([`aws_sqs_queue_redrive_allow_policy.results_dlq`](modules/results_writer/main.tf#L26), [`aws_sqs_queue_policy.results`](modules/results_writer/main.tf#L114)) — buffer con `maxReceiveCount = 3` y visibility timeout de 180s (≥6× el timeout de la Lambda)
- Lambda Python 3.12 en VPC con psycopg2: [`aws_lambda_function.writer`](modules/results_writer/main.tf#L163)
- Event Source Mapping: [`aws_lambda_event_source_mapping.sqs_results`](modules/results_writer/main.tf#L201)

La Lambda crea la tabla `transactions` si no existe (schema migration automático en cold start) e inserta con `ON CONFLICT DO NOTHING` para idempotencia (importante dado que SQS puede entregar el mismo mensaje más de una vez).

---

### `modules/api`

API REST serverless que sirve los datos del dashboard.

**Endpoints:**
| Método | Path | Descripción |
|--------|------|-------------|
| GET | `/health` | Health check con ping a RDS |
| GET | `/stats` | Totales: transacciones, bloqueadas, permitidas, challenge |
| GET | `/transactions?limit=N` | Últimas N transacciones (máx 100) |

**Recursos:** [`aws_lambda_function.api`](modules/api/main.tf#L51) (Python 3.12 en VPC + psycopg2), [`aws_apigatewayv2_api.main`](modules/api/main.tf#L88) (HTTP API), [`aws_apigatewayv2_stage.default`](modules/api/main.tf#L117) (`$default`, `auto_deploy = true`), integración y rutas: [`aws_apigatewayv2_integration.lambda`](modules/api/main.tf#L128), [`aws_apigatewayv2_route`](modules/api/main.tf#L135) (`/transactions`, `/stats`, `/health` y [catch-all `$default`](modules/api/main.tf#L154)).

---

### `modules/onprem_sim`

Simula un sitio corporativo on-premise conectado a AWS mediante una VPN Site-to-Site.

**Recursos:**
- VPC pública `192.168.0.0/16`: [`aws_vpc.onprem`](modules/onprem_sim/main.tf#L18), subnets/IGW/rutas en el mismo archivo; EC2 strongSwan vía [`aws_cloudformation_stack.strongswan`](modules/onprem_sim/main.tf#L225) y plantilla [`templates/vpn-gateway-strongswan.yml`](templates/vpn-gateway-strongswan.yml)
- VPN: [`aws_customer_gateway.cgw`](modules/onprem_sim/main.tf#L158), [`aws_vpn_connection.vpn`](modules/onprem_sim/main.tf#L168) (2 túneles BGP contra el VGW)
- PSKs: [`aws_secretsmanager_secret` / `secret_version` túnel 1 y 2](modules/onprem_sim/main.tf#L184)
- Route 53 Private Hosted Zone: [`aws_route53_zone.sqs_private`](modules/onprem_sim/main.tf#L296), [`aws_route53_record.sqs_apex`](modules/onprem_sim/main.tf#L314) — resuelve `sqs.<region>.amazonaws.com` a las IPs privadas del VPC Endpoint

Controlado por [`var.enable_onprem_sim`](variables.tf#L62) (default: `true`). Ponerlo en `false` destruye la simulación on-prem y elimina el CIDR lock de la cola de ingesta.

---

### `modules/dashboard`

Sitio web estático en S3 con el panel de operaciones. Muestra las últimas transacciones y estadísticas en tiempo real consumiendo la API Gateway.

**Recursos:** [`aws_s3_bucket.dashboard`](modules/dashboard/main.tf#L9), [`aws_s3_bucket_website_configuration.dashboard`](modules/dashboard/main.tf#L23), [`aws_s3_bucket_policy.dashboard`](modules/dashboard/main.tf#L41), objetos estáticos: [`aws_s3_object.index_html`](modules/dashboard/main.tf#L58), [`aws_s3_object.app_js`](modules/dashboard/main.tf#L72), [`aws_s3_object.config_js`](modules/dashboard/main.tf#L86) (`templatefile()` con la URL de API Gateway).

Los archivos `index.html` y `app.js` son subidos por el pipeline CI/CD mediante `aws s3 sync` después de cada build.

---

## Funciones y meta-argumentos de Terraform

### Funciones utilizadas

| Función | Dónde | Para qué |
|---------|-------|----------|
| `format()` | Todos los módulos | Construir nombres de recursos con prefijo del proyecto |
| `merge()` | Todos los módulos | Combinar `common_tags` con tags específicos del recurso |
| `cidrsubnet()` | `modules/network` | Calcular CIDRs de subnets privadas a partir del CIDR de la VPC |
| `toset()` | `modules/network` | Convertir la lista de servicios Gateway a set para `for_each` |
| `slice()` | `main.tf` | Tomar las primeras 2 AZs disponibles en la región |
| `jsonencode()` | `modules/queue`, `modules/results_writer`, `modules/data_store` | Serializar políticas IAM y configuraciones como JSON |
| `contains()` | Variables con `validation` | Validar que valores numéricos estén dentro de rangos permitidos |
| `can()` + `cidrhost()` | Variables con `validation` | Validar que CIDRs sean IPv4 válidos |
| `replace()` | `modules/network` | Normalizar nombres de endpoints (reemplazar `_` por `-`) |
| `templatefile()` | `modules/dashboard` | Inyectar la URL de API Gateway en `config.js` en deploy time |
| `filebase64sha256()` | `main.tf` | Hash del zip de la capa psycopg2 para detectar cambios |
| `filemd5()` | `modules/dashboard` | Hash de archivos estáticos del dashboard |
| `length()` | Validaciones y lógica de red | Contar elementos en listas |

### Meta-argumentos utilizados

| Meta-argumento | Dónde | Para qué |
|----------------|-------|----------|
| `for_each` | `modules/network` — VPC Endpoints | Crear un endpoint por servicio (sqs, ecr_api, ecr_dkr, logs, sns, s3, dynamodb) desde un mapa/set, evitando duplicar bloques de recurso |
| `count` | `main.tf` — `module.onprem_sim` | Crear o no la simulación on-prem según `var.enable_onprem_sim`. Permite habilitar/deshabilitar toda la infraestructura VPN con un flag |
| `lifecycle { ignore_changes }` | `modules/compute` — ECS Service | Ignora cambios en `desired_count` para que Application Auto Scaling sea el dueño del número de tasks, sin que Terraform lo revierta en cada apply |
| `lifecycle { ignore_changes }` | `modules/data_store` — RDS Instance | Ignora cambios en `password` para que Terraform no intente actualizar la contraseña (RDS no expone la contraseña actual al provider) |
| `lifecycle { ignore_changes }` | `modules/dashboard` — S3 Objects | Los archivos HTML/JS son actualizados por CI con `aws s3 sync`; Terraform los crea una vez y luego ignora cambios para no entrar en conflicto con el pipeline |
| `lifecycle { create_before_destroy }` | `main.tf` — Lambda Layer | Garantiza que la nueva versión de la capa psycopg2 esté disponible antes de destruir la anterior, evitando downtime en las Lambdas |
| `depends_on` | `modules/compute` — ECS Service | Fuerza que las reglas de egress del SG existan antes de crear el servicio ECS |
| `depends_on` | `modules/onprem_sim` — CloudFormation stack | Espera a que los Secrets Manager secret versions con los PSKs estén creados antes de levantar el router strongSwan |
| `validation` | Todas las variables | Valida tipos, rangos y formatos (CIDRs, ARNs, valores permitidos de CPU/memoria) en tiempo de `terraform plan`, antes de hacer ningún cambio en AWS |

---

## Prerequisites

- Terraform ≥ 1.9
- AWS CLI configurado con credenciales de AWS Academy (`aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`)
- Python 3 con pip (para construir la capa Lambda de psycopg2)
- `make`

## Configuración de variables de entorno

Antes de ejecutar los pasos a continuación, copiar el archivo terraform.tfvars.example a terraform.tfvars y ajustar los valores según el entorno.

```bash
cp terraform.tfvars.example terraform.tfvars
```

## Guía de ejecución paso a paso

### 1. Generar builds necesarios

```bash
make build-layers
```

### 2. Inicializar Terraform

Ejecutar:
```bash
make init
```

### 3. Planear

```bash
make plan
```

### 5. Aplicar

```bash
make apply
```

### 6. Verificar outputs

```bash
terraform output
```

Outputs relevantes:

| Output | Descripción |
|--------|-------------|
| `dashboard_url` | URL del dashboard web |
| `api_endpoint` | URL base de la API REST |
| `queue_url` | URL de la cola SQS de ingesta (on-prem envía aquí) |
| `sns_topic_arn` | ARN del topic SNS de resultados |
| `vpn_gateway_public_ip` | IP pública del router on-prem (strongSwan) |
| `db_password` | Contraseña RDS generada (sensible, usar `-raw`) |

---

## Probar el flujo completo

El flujo completo simula una transacción que llega desde el sitio on-prem, es evaluada por el motor de fraude y aparece en el dashboard.

### Paso 1 — Conectarse al on-prem simulado

El on-prem está implementado como una EC2 con strongSwan en la VPC `192.168.0.0/16`. Solo desde esa red puede enviarse mensajes al SQS de ingesta (el queue policy lo enforce con `aws:VpcSourceIp`).

```bash
# Obtener la IP pública del router on-prem
terraform output -raw vpn_gateway_public_ip
```

```bash
# SSH con el PEM del lab (el usuario varía según la AMI: ec2-user o ubuntu)
ssh -i labsuser.pem ec2-user@<ip_del_output>
```

### Paso 2 — Enviar una transacción desde on-prem

Una vez dentro del EC2:

```bash
# Configurar credenciales del lab (las mismas de tu sesión Academy)
aws configure set aws_access_key_id     <AWS_ACCESS_KEY_ID>
aws configure set aws_secret_access_key <AWS_SECRET_ACCESS_KEY>
aws configure set aws_session_token     <AWS_SESSION_TOKEN>
aws configure set region us-east-1

# Enviar transacción al SQS de ingesta
aws sqs send-message \
  --queue-url "<queue_url del output>" \
  --message-body '{
    "transaction_id": "demo-001",
    "user_id":        "user-123",
    "amount":         15000.00,
    "currency":       "USD",
    "country":        "BR",
    "channel":        "online",
    "destination_account": "acc-999",
    "timestamp":      "2026-05-17T10:00:00Z"
  }' \
  --region us-east-1
```

### Paso 3 — Verificar el procesamiento en Fargate

```bash
# Desde tu máquina local (no el EC2)
aws logs tail "/ecs/itba-tp-fraud-fraud-engine" --since 5m --region us-east-1
```

Deberías ver logs del scoring con `fraud_score` y `is_fraud`.

### Paso 4 — Verificar que la Lambda escribió en RDS

```bash
aws logs tail "/aws/lambda/itba-tp-fraud-results-writer" --since 5m --region us-east-1
```

Deberías ver: `"action": "fraud_result_stored", "transaction_id": "demo-001"`.

### Paso 5 — Ver el resultado en el dashboard

```bash
terraform output -raw dashboard_url
```

Abrir esa URL en el browser. Ingresar con:

| Campo | Valor |
|-------|-------|
| Usuario | `cloud` |
| Contraseña | `cloud` |

La transacción `demo-001` debería aparecer en la tabla con su score y decisión.

---

## Dashboard

El dashboard es un sitio web estático en S3 que consulta la API REST en tiempo real.

```bash
terraform output -raw dashboard_url
```

**Credenciales de acceso:** `cloud` / `cloud`

**Endpoints de la API:**

```bash
API=$(terraform output -raw api_endpoint)

curl "$API/health"                        # {"status": "ok"}
curl "$API/stats"                         # totales por decisión
curl "$API/transactions?limit=10"         # últimas 10 transacciones
```

---

## Tear down

Al finalizar la sesión del lab, destruir toda la infraestructura:

```bash
make destroy
```

El bucket de state S3 **no** es destruido por Terraform (fue creado fuera del state). Si se desea eliminarlo:

```bash
aws s3 rb "s3://itba-tp-fraud-tfstate-$(aws sts get-caller-identity --query Account --output text)" --force
```

---

## CI/CD

El repositorio tiene tres pipelines de GitHub Actions:

| Workflow | Trigger | Qué hace |
|----------|---------|----------|
| **Validate** | Todo push y PR | `terraform fmt -check` + `terraform validate` |
| **Plan** | Push a `main` y PRs contra `main` | `terraform plan` y postea el diff como comentario en el PR |
| **Docker** | Cambios en `app/` o PR/push a `main` | Build del procesador Go, push a ECR, `terraform apply` con el nuevo `image_uri`, deploy del dashboard a S3 |

Los secrets necesarios en GitHub: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`.

---

## Mapa del repositorio

```
.
├── main.tf                  # Composición raíz — wiring de todos los módulos
├── variables.tf             # Variables de entrada de la composición
├── outputs.tf               # Outputs expuestos
├── versions.tf              # Versiones de Terraform y providers
├── backend.tf               # Backend S3 (partial config, bucket se pasa en init)
├── terraform.tfvars.example # Plantilla de configuración
├── Makefile                 # Targets: init, plan, apply, destroy, build-layers
├── modules/
│   ├── network/             # VPC, subnets, VPN Gateway, VPC Endpoints
│   ├── queue/               # SQS ingesta + DLQ + CIDR lock on-prem
│   ├── data_store/          # DynamoDB + RDS + RDS Proxy + Secrets Manager
│   ├── compute/             # ECR + ECS Fargate + Auto Scaling
│   ├── onprem_sim/          # VPC on-prem + strongSwan EC2 + VPN site-to-site
│   ├── notification/        # SNS topic + suscripción email opcional
│   ├── results_writer/      # SQS resultados + Lambda writer (SNS→SQS→Lambda→RDS)
│   ├── api/                 # Lambda API + HTTP API Gateway
│   └── dashboard/           # S3 bucket + website config + config.js templating
├── app/
│   ├── processor/           # Motor de scoring en Go (SQS consumer → SNS publisher)
│   ├── api/                 # API Flask (referencia/CI check, no deployada como Lambda)
│   └── dashboard/           # Frontend vanilla JS (index.html, app.js)
├── layers/
│   └── psycopg2/            # Layer psycopg2 (generado por make build-layers)
├── templates/
│   └── vpn-gateway-strongswan.yml  # CloudFormation template del router on-prem
├── ARCHITECTURE.md          # Arquitectura detallada y trade-offs
├── CONTRIBUTING.md          # Branching, commits, PR checklist
└── docs/
    ├── STYLE_GUIDE.md       # Convenciones HCL
    ├── NAMING.md            # Nomenclatura de recursos
    ├── WORKFLOW.md          # Flujo init/plan/apply
    ├── SECURITY.md          # Qué nunca commitear
    └── CONSIGNA.md          # Requisitos del trabajo práctico
```
