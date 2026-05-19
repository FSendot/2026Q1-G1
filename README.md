# Fraud Detector — Infraestructura como Código

Sistema de detección de fraude en tiempo real desplegado en AWS mediante Terraform.
Transacciones financieras ingresan desde un sitio on-premise simulado, son procesadas por un motor de scoring corriendo en Fargate, y los resultados quedan disponibles en un dashboard web.

La arquitectura detallada está en `[ARCHITECTURE.md](ARCHITECTURE.md)`.

**Flujo de datos:**

1. Dos instancias EC2 on-prem (`producer-1`, `producer-2`) envían transacciones JSON al SQS de ingesta de forma continua (~2.000 tx/min cada una) a través del túnel VPN; opcionalmente podés lanzar picos manuales con `scripts/send_test_transactions.py`.
2. Fargate consume el mensaje, consulta el perfil del usuario en DynamoDB y calcula el fraud score
3. El resultado se envía directo al SQS de resultados; si es fraude, también se encola en el SQS de alertas
4. La Lambda `results-writer` toma el mensaje de resultados de SQS y persiste el resultado en RDS vía RDS Proxy
5. La Lambda `fraud-summary` se ejecuta cada `fraud_alert_summary_interval_minutes`, resume los fraudes pendientes y publica un único email vía SNS
6. La Lambda `api` expone esos datos a través de API Gateway
7. El dashboard (S3 website) consume la API y muestra el estado en tiempo real

---

## Operaciones con GitHub Actions

**GitHub Actions es el camino recomendado** para desplegar, probar y destruir la infraestructura del lab. Los workflows construyen los artefactos necesarios, inicializan el backend S3 y ejecutan Terraform sin depender de herramientas locales.

### Requisitos previos


| Requisito               | Detalle                                                          |
| ----------------------- | ---------------------------------------------------------------- |
| Repositorio en GitHub   | Fork o clone de este proyecto                                    |
| Lab AWS Academy         | Sesión activa; las credenciales temporales expiran cada ~4 h     |
| Secrets del repositorio | Ver tabla siguiente                                              |
| Rama `main`             | Requerida para que **Docker** ejecute el deploy completo en push |


**Secrets del repositorio** (Settings → Secrets and variables → Actions):

**Mínimo para cualquier workflow que toque AWS** (Plan, Docker en `main`, Apply, Send test transactions, Destroy):


| Secret                  | ¿Obligatorio? |
| ----------------------- | ------------- |
| `AWS_ACCESS_KEY_ID`     | Sí            |
| `AWS_SECRET_ACCESS_KEY` | Sí            |
| `AWS_SESSION_TOKEN`     | Sí            |


Los tres forman un set indivisible: credenciales temporales del lab AWS Academy. Sin ellos, esos workflows fallan al autenticarse contra AWS.

**Secrets opcionales** (el workflow corre igual si no existen):


| Secret                       | Qué ingresar                                                                                                 | Función                                                                                                                                                                                                                                     |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BOOTSTRAP_EMAIL`            | Tu email real de acceso al dashboard, p. ej. `nombre.apellido@itba.edu.ar`                                   | Crea el **primer admin del dashboard** en RDS. Sin este secret el deploy termina bien, pero nadie puede administrar invitaciones hasta correr bootstrap a mano.                                                                             |
| `BOOTSTRAP_PASSWORD`         | Una contraseña permanente para Cognito que cumpla la política del User Pool, p. ej. `UnaPasswordDemo123!`    | Solo tiene efecto si también existe `BOOTSTRAP_EMAIL`. Crea o actualiza el usuario Cognito con ese email, marca el correo como verificado y fija la contraseña.                                                                             |
| `BOOTSTRAP_ALERT_EMAIL`      | Otro email válido, p. ej. `alertas@example.com`                                                              | Solo tiene efecto si también existe `BOOTSTRAP_EMAIL`. Durante el bootstrap, suscribe ese email al **topic SNS de resúmenes de fraude** para recibir los emails agregados de transacciones fraudulentas.                                    |
| `GOOGLE_OAUTH_CLIENT_ID`     | Client ID de una OAuth 2.0 Client en Google Cloud Console, p. ej. `123456789-abc.apps.googleusercontent.com` | Solo tiene efecto en **Docker** / **Apply** si **ambos** secrets Google están definidos. Terraform configura Cognito con Google como identity provider; en el login del dashboard aparece **“Sign in with Google”** además del login local. |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Client secret asociado al mismo OAuth client de Google                                                       | Par obligatorio con `GOOGLE_OAUTH_CLIENT_ID`. Sin los dos, Cognito queda solo con login por email/contraseña. En Google Cloud hay que registrar el redirect URI de Cognito (ver sección [Dashboard Auth](#dashboard-auth)).                 |


**Combinaciones habituales:**


| Objetivo                                      | Secrets a configurar                                                                                 |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Deploy mínimo                                 | Solo los 3 AWS                                                                                       |
| Primer login al dashboard sin pasos manuales  | 3 AWS + `BOOTSTRAP_EMAIL` + `BOOTSTRAP_PASSWORD`                                                     |
| Admin en un email y alertas de fraude en otro | 3 AWS + `BOOTSTRAP_EMAIL` + `BOOTSTRAP_ALERT_EMAIL` (+ `BOOTSTRAP_PASSWORD` si querés login directo) |
| Login con Google                              | 3 AWS + `GOOGLE_OAUTH_CLIENT_ID` + `GOOGLE_OAUTH_CLIENT_SECRET` (+ bootstrap si aplica)              |


**Secrets obligatorios por workflow:**


| Workflow                                            | Secrets obligatorios                                              | Secrets opcionales              | Sin secrets                    |
| --------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------- | ------------------------------ |
| **Validate**                                        | —                                                                 | —                               | Sí (no usa AWS ni bootstrap)   |
| **Plan**                                            | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | —                               | No                             |
| **Docker** (PR / rama ≠ `main`)                     | —                                                                 | —                               | Sí (solo valida builds Docker) |
| **Docker** (`main` o `workflow_dispatch` en `main`) | Los 3 AWS                                                         | `BOOTSTRAP_*`, `GOOGLE_OAUTH_*` | No                             |
| **Apply**                                           | Los 3 AWS                                                         | `BOOTSTRAP_*`, `GOOGLE_OAUTH_*` | No                             |
| **Send test transactions**                          | Los 3 AWS                                                         | —                               | No                             |
| **Destroy**                                         | Los 3 AWS                                                         | —                               | No                             |


**Recomendado para el primer deploy:** los 3 AWS + `BOOTSTRAP_EMAIL`. Sin `BOOTSTRAP_EMAIL` el deploy termina bien, pero hay que crear el admin del dashboard a mano con `make bootstrap-auth` en local.

Los workflows **no leen `terraform.tfvars`**. Los defaults del lab están en la composición raíz y en `[terraform.tfvars.example](terraform.tfvars.example)`. Para ajustar variables solo en local, ver [Desarrollo local (opcional)](#desarrollo-local-opcional).

**Renovar credenciales:** cuando el lab expira, actualizar los tres secrets AWS antes de relanzar cualquier workflow que toque la cuenta.

### Catálogo de workflows

Ejecutar manualmente: pestaña **Actions** → elegir workflow → **Run workflow**.


| Workflow                   | Trigger                                               | Cuándo usarlo                                   | Requisitos previos                                             |
| -------------------------- | ----------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------- |
| **Validate**               | Push y PR a cualquier rama                            | CI en cada cambio                               | Ninguno (sin AWS)                                              |
| **Plan**                   | Push/PR a `main`                                      | Revisar diff antes de merge                     | Secrets AWS; crea el bucket de state en el primer run          |
| **Docker**                 | Push a `main` (paths filtrados) o `workflow_dispatch` | Deploy completo (camino CD principal)           | Secrets AWS; en `main`: apply + dashboard + bootstrap opcional |
| **Apply**                  | `workflow_dispatch`                                   | Apply Terraform sin rebuild de imagen/dashboard | Secrets AWS; escribir `apply` en el input de confirmación      |
| **Send test transactions** | `workflow_dispatch`                                   | Carga de prueba post-deploy                     | Secrets AWS + infra levantada + `enable_onprem_sim = true`     |
| **Destroy**                | `workflow_dispatch`                                   | Fin de sesión del lab                           | Secrets AWS; escribir `destroy` en el input de confirmación    |


**Paths que disparan Docker en push a `main`:** `app/processor/`**, `app/dashboard/**`, `app/results_writer/**`, `app/net/serving/go/**`, `modules/**`, `scripts/**`, `templates/**`, `main.tf`, `variables.tf`, `outputs.tf`, `.github/workflows/docker.yml`.

En PRs contra `main`, **Docker** solo valida builds (processor + dashboard export) sin tocar AWS.

#### Docker en `main` (deploy principal)

Secuencia real del workflow `[.github/workflows/docker.yml](.github/workflows/docker.yml)`:

1. `make prepare-model`
2. Build/push de imagen del processor a ECR (reutiliza por hash de fuentes si ya existe)
3. `make init` → `terraform plan/apply` con `image_uri`
4. Build del dashboard con build-args de Cognito/API → `aws s3 sync` a S3
5. `make bootstrap-auth` si `BOOTSTRAP_EMAIL` está configurado

#### Apply (alternativa manual)

Usar **Apply** cuando los cambios no entran en los path filters de Docker (por ejemplo, solo HCL fuera de esas rutas) o cuando se necesita un `terraform apply` sin reconstruir imagen ni dashboard. Escribir `apply` en el campo de confirmación.

### Primer deploy (checklist)

1. Configurar secrets en GitHub (mínimo: los tres AWS; recomendado: `BOOTSTRAP_EMAIL`).
2. Push/merge a `main` **o** ejecutar **Docker** / **Apply** con `workflow_dispatch`.
3. Esperar run verde; abrir el **job summary** del run (tabla *Deployment outputs* con `dashboard_url`, `api_endpoint`, `queue_url`).
4. Ejecutar **Send test transactions** (`workflow_dispatch`, defaults abajo).
5. Abrir `dashboard_url` del summary; completar registro Cognito si no se definió `BOOTSTRAP_PASSWORD`.

### Probar el flujo completo


| Paso                   | Camino principal (Actions)                      | Después del run                                                                                                                       |
| ---------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Enviar transacciones   | **Send test transactions**                      | Inputs: `count` (default `50000`), `fraud_pct` (`20`), `concurrency` (`128`), `region`, `stack`; opcional `queue_url` / `instance_id` |
| Ver logs del processor | Sin workflow                                    | Opcional local: `make logs` (AWS CLI + credenciales; ver [Desarrollo local](#desarrollo-local-opcional))                              |
| Abrir dashboard        | URL en el job summary de **Docker** / **Apply** | Login Cognito Hosted UI                                                                                                               |


**Send test transactions** obtiene el instance ID del EC2 on-prem desde CloudFormation y la queue URL desde `terraform output` (salvo overrides). El generador Go corre en el EC2 vía SSM (`AWS-RunShellScript`); el tráfico SQS viaja por VPN al Interface VPC Endpoint. En el EC2, el generador firma requests con SigV4 y envía batches de hasta 10 mensajes; `concurrency` controla workers simultáneos.

El processor en Fargate expone `processor_pollers` (long-pollers SQS por task) y `processor_concurrency` (workers paralelos). Para pruebas de límite, subir `processor_concurrency`, `processor_pollers`, `max_capacity` y `concurrency` del workflow en conjunto. El worker serializa por `user_id` dentro de cada task; la cola es Standard SQS (sin orden global entre tasks).

Patrones de transacción generados:

- **Normal:** usuarios recurrentes/nuevos, importes bajos/medios, beneficiarios conocidos, dispositivo estable, gaps de horas o días.
- **Fraude:** account drain, country shift, device/identity shift, merchant fanout, card testing, gaps de segundos/minutos.

### Outputs tras un deploy

Los workflows **Docker** (solo `main`) y **Apply** escriben una tabla en el job summary:


| Output              | Uso                                               |
| ------------------- | ------------------------------------------------- |
| `dashboard_url`     | Entrada recomendada al dashboard (Cognito + PKCE) |
| `dashboard_app_url` | Mismo objeto HTTPS que `dashboard_url`            |
| `api_endpoint`      | Base URL de la API REST                           |
| `queue_url`         | Cola SQS de ingesta (on-prem → aquí)              |


Outputs adicionales disponibles solo vía CLI local: ver [Verificar outputs](#6-verificar-outputs).

### Tear down

Al finalizar la sesión del lab:

1. Actions → **Destroy** → Run workflow.
2. Escribir `destroy` en el input de confirmación.
3. Esperar run verde.

El bucket de state S3 `itba-tp-fraud-tfstate-<account-id>` **no** se elimina (vive fuera del state de Terraform). Para borrarlo manualmente, ver [Desarrollo local (opcional)](#desarrollo-local-opcional).

---

## Módulos

### `modules/network`

Provisiona la VPC privada que aloja toda la infraestructura. No tiene NAT Gateway ni Internet Gateway. Todo el egress a servicios AWS fluye por VPC Endpoints, reduciendo costos y superficie de ataque.

**Recursos clave:**

- `[module "vpc"](modules/network/main.tf#L22)` (`terraform-aws-modules/vpc/aws`): VPC `10.0.0.0/16` con 2 subnets privadas en distintas AZs; Virtual Private Gateway (VGW) para la VPN site-to-site vía `[enable_vpn_gateway](modules/network/main.tf#L38)`
- **Gateway VPC Endpoints** (S3, DynamoDB): `[aws_vpc_endpoint.gateway](modules/network/main.tf#L83)`
- **Interface VPC Endpoints** (SQS, ECR API, ECR DKR, CloudWatch Logs, SNS, Secrets Manager, Cognito IDP): `[aws_vpc_endpoint.interface](modules/network/main.tf#L97)`
- Cuando la simulación on-prem está habilitada, el Security Group de endpoints también permite HTTPS desde `192.168.0.0/16` para que el EC2 on-prem resuelva `sqs.<region>.amazonaws.com` hacia el VPCE y envíe tráfico por la VPN.

**Módulo externo**: el pin `~> 5.13` está en `[modules/network/main.tf](modules/network/main.tf#L22)`; los VPC Endpoints propios son los recursos enlazados arriba.

---

### `modules/queue`

Cola SQS de ingesta de transacciones con Dead Letter Queue. El acceso está restringido al rol IAM `LabRole` (único principal autorizado para `SendMessage`/`ReceiveMessage`) y se deniega cualquier tráfico no cifrado (`aws:SecureTransport = false`). La restricción de red queda garantizada arquitecturalmente por la combinación VPN Site-to-Site + Interface VPC Endpoint: el endpoint SQS solo es alcanzable desde dentro de la VPC, y la VPN es el único camino desde el on-prem hasta ella. Se intentó agregar un `Deny` explícito por CIDR/VPC mediante `aws:VpcSourceIp` y `aws:SourceVpc`, pero estas condition keys no se propagan para tráfico cross-VPC vía VPN hacia Interface Endpoints.

**Recursos:** `[aws_sqs_queue.main](modules/queue/main.tf#L31)` + `[aws_sqs_queue.dlq](modules/queue/main.tf#L10)`, `[aws_sqs_queue_redrive_allow_policy.dlq](modules/queue/main.tf#L22)`, `[aws_sqs_queue_policy.main](modules/queue/main.tf#L98)` y `[aws_sqs_queue_policy.dlq](modules/queue/main.tf#L143)`

---

### `modules/data_store`

Toda la capa de persistencia del sistema en un único módulo:

- **DynamoDB** `itba-tp-fraud-user-behavior`: `[aws_dynamodb_table.user_behavior](modules/data_store/main.tf#L13)` — perfiles de comportamiento de usuarios. Clave de partición `user_id`. Consultado por Fargate durante el scoring para enriquecer la decisión con historial del usuario.
- **RDS PostgreSQL 17.4** `itba-tp-fraud-results-db`: `[aws_db_instance.results](modules/data_store/main.tf#L118)` almacena los resultados de scoring (`transaction_id`, `fraud_score`, `is_fraud`, `decision`, `processed_at`, etc.). Acceso exclusivo desde dentro de la VPC a través del RDS Proxy.
- **Secrets Manager**: `[aws_secretsmanager_secret.db_credentials](modules/data_store/main.tf#L161)` y `[aws_secretsmanager_secret_version](modules/data_store/main.tf#L172)` — credenciales RDS en JSON para autenticación del proxy.
- **RDS Proxy**: `[aws_db_proxy.results](modules/data_store/main.tf#L194)`, `[aws_db_proxy_default_target_group](modules/data_store/main.tf#L216)`, `[aws_db_proxy_target](modules/data_store/main.tf#L230)` — pool entre Lambdas y RDS; mitiga el agotamiento de conexiones en `db.t3.micro` (~50 conexiones máx).
- **Security Group del proxy**: `[aws_security_group.proxy](modules/data_store/main.tf#L182)`; las reglas cruzadas con Lambdas/RDS están en la raíz — `[main.tf](main.tf#L169)` (`proxy_to_rds`, `rds_from_proxy`, `writer_lambda_to_proxy`, `api_lambda_to_proxy`, etc.) para evitar dependencias circulares entre módulos.

---

### `modules/compute`

Motor de scoring corriendo en ECS Fargate. Lee transacciones de SQS, consulta DynamoDB, aplica el modelo ML (con fallback a reglas si el modelo no está disponible), publica todos los resultados en la cola de persistencia, y publica sólo fraudes en la cola de resúmenes.

**Recursos:** `[aws_ecr_repository.app](modules/compute/main.tf#L48)`, `[aws_ecs_cluster.main](modules/compute/main.tf#L78)` (Container Insights en el cluster), `[aws_ecs_task_definition.app](modules/compute/main.tf#L142)`, `[aws_ecs_service.app](modules/compute/main.tf#L165)`, Application Auto Scaling (`[aws_appautoscaling_target](modules/compute/main.tf#L194)`, `[aws_appautoscaling_policy](modules/compute/main.tf#L204)`).

**Auto Scaling**: política de target tracking con métrica compuesta `messages_per_task = ApproximateNumberOfMessagesVisible / max(RunningTaskCount, 1)`. Si el backlog supera 10 mensajes por task, escala horizontalmente hasta 10 tasks.

**Variables de entorno del contenedor**: `QUEUE_URL`, `RESULTS_QUEUE_URL`, `FRAUD_ALERT_QUEUE_URL`, `DYNAMODB_TABLE_NAME`, `AWS_REGION`, `S3_AUDIT_BUCKET`.

---

### `modules/notification`

Composición de alertas resumidas. El processor no publica resultados crudos en SNS: encola sólo los fraudes en `itba-tp-fraud-fraud-alerts`, una Lambda programada cada `fraud_alert_summary_interval_minutes` minutos genera un resumen, y SNS lo distribuye a los emails confirmados.

**Recursos:** submódulos `[topic](modules/notification/topic/main.tf)`, `[summary_queue](modules/notification/summary_queue/main.tf)` y `[summarizer](modules/notification/summarizer/main.tf)`.

---

### `modules/results_writer`

Pipeline SQS → Lambda para persistir resultados en RDS. El processor envía cada resultado directamente a esta cola.

**Recursos:**

- SQS `itba-tp-fraud-results-events` + DLQ: `[aws_sqs_queue.results](modules/results_writer/main.tf#L35)` + `[aws_sqs_queue.results_dlq](modules/results_writer/main.tf#L14)` (`[aws_sqs_queue_redrive_allow_policy.results_dlq](modules/results_writer/main.tf#L26)`, `[aws_sqs_queue_policy.results](modules/results_writer/main.tf#L114)`) — buffer con `maxReceiveCount = 3` y visibility timeout de 180s (≥6× el timeout de la Lambda)
- Lambda Python 3.12 en VPC con psycopg2: `[aws_lambda_function.writer](modules/results_writer/main.tf#L163)`
- Event Source Mapping: `[aws_lambda_event_source_mapping.sqs_results](modules/results_writer/main.tf#L201)`

La Lambda crea la tabla `transactions` si no existe (schema migration automático en cold start) e inserta con `ON CONFLICT DO NOTHING` para idempotencia (importante dado que SQS puede entregar el mismo mensaje más de una vez).

---

### `modules/api`

API REST serverless protegida por Cognito que sirve los datos del dashboard.

**Endpoints:**


| Método | Path                      | Descripción                                                                                           |
| ------ | ------------------------- | ----------------------------------------------------------------------------------------------------- |
| GET    | `/health`                 | Health check con ping a RDS (requiere JWT Cognito)                                                    |
| GET    | `/dashboard/me`           | Perfil del dashboard user autenticado; activa invitaciones pendientes si el email verificado coincide |
| GET    | `/dashboard/invites`      | Lista de invitaciones/accesos del dashboard (solo bootstrap admin)                                    |
| POST   | `/dashboard/invites`      | Crea o reactiva una invitación por email (solo bootstrap admin)                                       |
| DELETE | `/dashboard/invites/{id}` | Soft-disable de un acceso de dashboard (solo bootstrap admin; no aplica al bootstrap admin)           |
| PUT    | `/dashboard/me/password`  | Cambio de contraseña para usuarios Cognito locales                                                    |
| GET    | `/stats`                  | Totales: transacciones, bloqueadas, permitidas, challenge                                             |
| GET    | `/transactions?limit=N`   | Últimas N transacciones (máx 100)                                                                     |


**Recursos:** `[aws_lambda_function.api](modules/api/main.tf#L51)` (Python 3.12 en VPC + psycopg2), `[aws_apigatewayv2_api.main](modules/api/main.tf#L88)` (HTTP API), `[aws_apigatewayv2_stage.default](modules/api/main.tf#L117)` (`$default`, `auto_deploy = true`), integración y rutas: `[aws_apigatewayv2_integration.lambda](modules/api/main.tf#L128)`, `[aws_apigatewayv2_route](modules/api/main.tf#L135)` (`/transactions`, `/stats`, `/health` y [catch-all `$default](modules/api/main.tf#L154)`).

---

### `modules/onprem_sim`

Simula un sitio corporativo on-premise conectado a AWS mediante una VPN Site-to-Site.

**Recursos:**

- VPC pública `192.168.0.0/16`: `[aws_vpc.onprem](modules/onprem_sim/main.tf#L18)`, subnets/IGW/rutas en el mismo archivo; EC2 strongSwan vía `[aws_cloudformation_stack.strongswan](modules/onprem_sim/main.tf#L225)` y plantilla `[templates/vpn-gateway-strongswan.yml](templates/vpn-gateway-strongswan.yml)`
- Productores de tráfico: `[aws_instance.producer](modules/onprem_sim/producers.tf)` (`for_each` → `producer-1`, `producer-2`) con servicio `systemd` `onprem-tx-producer` que envía transacciones sintéticas continuas a la cola de ingesta (~200 msgs / 6 s por instancia)
- VPN: `[aws_customer_gateway.cgw](modules/onprem_sim/main.tf#L158)`, `[aws_vpn_connection.vpn](modules/onprem_sim/main.tf#L168)` (2 túneles BGP contra el VGW)
- PSKs: `[aws_secretsmanager_secret` / `secret_version` túnel 1 y 2](modules/onprem_sim/main.tf#L184)
- Route 53 Private Hosted Zone: `[aws_route53_zone.sqs_private](modules/onprem_sim/main.tf#L296)`, `[aws_route53_record.sqs_apex](modules/onprem_sim/main.tf#L314)` — resuelve `sqs.<region>.amazonaws.com` a las IPs privadas del VPC Endpoint

Controlado por `[var.enable_onprem_sim](variables.tf#L106)` (default: `true`) y `[var.enable_onprem_traffic_producers](variables.tf#L112)` (default: `true`). Poner `enable_onprem_sim = false` destruye la simulación on-prem; `enable_onprem_traffic_producers = false` elimina solo los EC2 productores.

---

### `modules/dashboard`

Sitio web estático en S3 con el panel de operaciones. Muestra las últimas transacciones y estadísticas en tiempo real consumiendo la API Gateway.

**Recursos:** `[aws_s3_bucket.dashboard](modules/dashboard/main.tf#L9)`, `[aws_s3_bucket_website_configuration.dashboard](modules/dashboard/main.tf#L23)`, `[aws_s3_bucket_policy.dashboard](modules/dashboard/main.tf#L41)`, objetos estáticos: `[aws_s3_object.index_html](modules/dashboard/main.tf#L58)`, `[aws_s3_object.app_js](modules/dashboard/main.tf#L72)`, `[aws_s3_object.config_js](modules/dashboard/main.tf#L86)` (`templatefile()` con la URL de API Gateway).

Los archivos `index.html` y `app.js` son subidos por el pipeline CI/CD mediante `aws s3 sync` después de cada build.

### `modules/auth`

Capa de autenticación del dashboard. Crea un Cognito User Pool con email como identidad de acceso, self-signup habilitado, Hosted UI, dominio administrado `itba-fraud-auth-<account-id>` y un app client público para flujo Authorization Code + PKCE. Google OAuth es opcional y sólo se habilita si se pasan `GOOGLE_OAUTH_CLIENT_ID` y `GOOGLE_OAUTH_CLIENT_SECRET` al plan/apply.

La autorización final no vive sólo en Cognito: la Lambda API mantiene una tabla `dashboard_access` en RDS. Un usuario puede autenticarse correctamente en Cognito y aun así quedar bloqueado si su email verificado no fue pre-invitado por el bootstrap admin.

---

## Funciones y meta-argumentos de Terraform

### Funciones utilizadas


| Función                | Dónde                                                           | Para qué                                                        |
| ---------------------- | --------------------------------------------------------------- | --------------------------------------------------------------- |
| `format()`             | Todos los módulos                                               | Construir nombres de recursos con prefijo del proyecto          |
| `merge()`              | Todos los módulos                                               | Combinar `common_tags` con tags específicos del recurso         |
| `cidrsubnet()`         | `modules/network`                                               | Calcular CIDRs de subnets privadas a partir del CIDR de la VPC  |
| `toset()`              | `modules/network`                                               | Convertir la lista de servicios Gateway a set para `for_each`   |
| `slice()`              | `main.tf`                                                       | Tomar las primeras 2 AZs disponibles en la región               |
| `jsonencode()`         | `modules/queue`, `modules/results_writer`, `modules/data_store` | Serializar políticas IAM y configuraciones como JSON            |
| `contains()`           | Variables con `validation`                                      | Validar que valores numéricos estén dentro de rangos permitidos |
| `can()` + `cidrhost()` | Variables con `validation`                                      | Validar que CIDRs sean IPv4 válidos                             |
| `replace()`            | `modules/network`                                               | Normalizar nombres de endpoints (reemplazar `_` por `-`)        |
| `templatefile()`       | `modules/dashboard`                                             | Inyectar la URL de API Gateway en `config.js` en deploy time    |
| `filebase64sha256()`   | `main.tf`                                                       | Hash del zip de la capa psycopg2 para detectar cambios          |
| `filemd5()`            | `modules/dashboard`                                             | Hash de archivos estáticos del dashboard                        |
| `length()`             | Validaciones y lógica de red                                    | Contar elementos en listas                                      |


### Meta-argumentos utilizados


| Meta-argumento                        | Dónde                                       | Para qué                                                                                                                                                             |
| ------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `for_each`                            | `modules/network` — VPC Endpoints           | Crear un endpoint por servicio (sqs, ecr_api, ecr_dkr, logs, sns, secretsmanager, cognito_idp, s3, dynamodb) desde un mapa/set, evitando duplicar bloques de recurso |
| `count`                               | `main.tf` — `module.onprem_sim`             | Crear o no la simulación on-prem según `var.enable_onprem_sim`. Permite habilitar/deshabilitar toda la infraestructura VPN con un flag                               |
| `lifecycle { ignore_changes }`        | `modules/compute` — ECS Service             | Ignora cambios en `desired_count` para que Application Auto Scaling sea el dueño del número de tasks, sin que Terraform lo revierta en cada apply                    |
| `lifecycle { ignore_changes }`        | `modules/data_store` — RDS Instance         | Ignora cambios en `password` para que Terraform no intente actualizar la contraseña (RDS no expone la contraseña actual al provider)                                 |
| `lifecycle { ignore_changes }`        | `modules/dashboard` — S3 Objects            | Los archivos HTML/JS son actualizados por CI con `aws s3 sync`; Terraform los crea una vez y luego ignora cambios para no entrar en conflicto con el pipeline        |
| `lifecycle { create_before_destroy }` | `main.tf` — Lambda Layer                    | Garantiza que la nueva versión de la capa psycopg2 esté disponible antes de destruir la anterior, evitando downtime en las Lambdas                                   |
| `depends_on`                          | `modules/compute` — ECS Service             | Fuerza que las reglas de egress del SG existan antes de crear el servicio ECS                                                                                        |
| `depends_on`                          | `modules/onprem_sim` — CloudFormation stack | Espera a que los Secrets Manager secret versions con los PSKs estén creados antes de levantar el router strongSwan                                                   |
| `validation`                          | Todas las variables                         | Valida tipos, rangos y formatos (CIDRs, ARNs, valores permitidos de CPU/memoria) en tiempo de `terraform plan`, antes de hacer ningún cambio en AWS                  |


---

## Desarrollo local (opcional)

Usar la consola local solo cuando haga falta: tail de logs en vivo, depuración offline, o ajustes en `terraform.tfvars`. Para deploy, pruebas de carga y teardown, preferir [Operaciones con GitHub Actions](#operaciones-con-github-actions).

### Prerrequisitos (solo local)

- Terraform ≥ 1.9
- AWS CLI con credenciales del lab (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`)
- Python 3 + pip (capa Lambda psycopg2, `send-test-tx`, `bootstrap-auth`)
- Go (build de `results-writer`)
- `make`
- Docker (solo si se construye processor/dashboard fuera de CI)

### Configuración de variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Ajustar valores según el entorno. No commitear `terraform.tfvars` (ver `[docs/SECURITY.md](docs/SECURITY.md)`).

### Cadena de dependencias

```
terraform.tfvars  →  make build-layers + make build-results-writer  →  make init  →  make plan  →  make apply
```

`make plan` y `make validate` ejecutan los builds automáticamente. Si se invoca `terraform plan` / `apply` / `validate` directamente, los artefactos deben existir antes porque Terraform calcula sus hashes en el plan.

### Comandos locales


| Objetivo             | Comando               | Depende de                      |
| -------------------- | --------------------- | ------------------------------- |
| Init                 | `make init`           | Credenciales AWS activas        |
| Plan                 | `make plan`           | init + builds                   |
| Apply                | `make apply`          | `tfplan` revisado               |
| Destroy              | `make destroy`        | init                            |
| Enviar transacciones | `make send-test-tx`   | init, `boto3`, infra desplegada |
| Logs Fargate         | `make logs`           | Credenciales AWS                |
| Bootstrap admin      | `make bootstrap-auth` | init, deploy completado         |


### Guía de ejecución paso a paso

#### 1. Generar builds necesarios

```bash
make build-layers
make build-results-writer
```

#### 2. Inicializar Terraform

```bash
make init
```

#### 3. Planear

```bash
make plan
```

#### 4. Aplicar

```bash
make apply
```

#### 5. Bootstrap admin (si no corrió en CI)

```bash
make bootstrap-auth BOOTSTRAP_EMAIL=tu-email@example.com
```

#### 6. Verificar outputs

```bash
terraform output
```


| Output                  | Descripción                                                  |
| ----------------------- | ------------------------------------------------------------ |
| `dashboard_url`         | URL HTTPS recomendada para abrir el dashboard con Cognito    |
| `dashboard_website_url` | Endpoint HTTP de S3 website; no usar como entrada de Cognito |
| `api_endpoint`          | URL base de la API REST                                      |
| `queue_url`             | URL de la cola SQS de ingesta (on-prem envía aquí)           |
| `sns_topic_arn`         | ARN del topic SNS de resúmenes de fraude                     |
| `fraud_alert_queue_url` | URL de la cola SQS que alimenta los resúmenes de fraude      |
| `vpn_gateway_public_ip` | IP pública del router on-prem (strongSwan)                   |
| `db_password`           | Contraseña RDS generada (sensible, usar `-raw`)              |


### Probar el flujo desde la consola

Equivalente local a los workflows de Actions:

```bash
python3 -m pip install boto3
make init
make send-test-tx
```

Parámetros opcionales:

```bash
make send-test-tx TX_COUNT=10000 FRAUD_PCT=30 TX_CONCURRENCY=256
```

```bash
make logs
terraform output -raw dashboard_url
```

### Tear down local

```bash
make destroy
```

Eliminar el bucket de state manualmente (opcional):

```bash
aws s3 rb "s3://itba-tp-fraud-tfstate-$(aws sts get-caller-identity --query Account --output text)" --force
```

---

## Dashboard

El dashboard es un sitio web estático en S3 que consulta la API REST en tiempo real. Tras un deploy exitoso (**Docker** o **Apply**), la URL aparece en el job summary como `dashboard_url`. También se puede obtener localmente:

```bash
terraform output -raw dashboard_url
```

La URL anterior es el objeto HTTPS `index.html` y es la entrada correcta para Cognito Hosted UI. El endpoint HTTP de S3 website existe como salida separada, pero no sirve como entrada de login porque PKCE necesita un contexto seguro del navegador.

```bash
terraform output -raw dashboard_website_url
```

Si necesitás la salida histórica usada por el build, `dashboard_app_url` apunta al mismo objeto HTTPS que `dashboard_url`.

### Dashboard Auth

El dashboard distingue entre:

- **Transaction User**: `user_id` interno de las transacciones financieras.
- **Dashboard User**: persona autenticada en Cognito que quiere ver el dashboard.

Cognito autentica. RDS autoriza. La tabla `dashboard_access` permite que el bootstrap admin invite emails antes de que el usuario se registre. Cuando el usuario entra con Cognito y su email está verificado, `/dashboard/me` activa la invitación pendiente y recién ahí el dashboard carga datos financieros.

**Bootstrap automático (recomendado):** si `BOOTSTRAP_EMAIL` está configurado como secret, los workflows **Docker** (`main`) y **Apply** ejecutan `make bootstrap-auth` al final del deploy. Con `BOOTSTRAP_PASSWORD` opcional, también crean o resetean el usuario Cognito.

**Bootstrap manual (opcional):**

```bash
make bootstrap-auth BOOTSTRAP_EMAIL=tu-email@example.com
```

Con contraseña permanente en Cognito:

```bash
make bootstrap-auth BOOTSTRAP_EMAIL=tu-email@example.com BOOTSTRAP_PASSWORD='UnaPasswordDemo123'
```

`BOOTSTRAP_PASSWORD` es opcional. Si no se pasa, el script sólo crea el acceso admin en RDS y el admin debe registrarse por Cognito Hosted UI con el mismo email. El script es idempotente y falla si ya existe otro bootstrap admin distinto.

Las invitaciones no envían emails. El bootstrap admin crea el invite desde la pestaña **Invitaciones**; el invitado entra por la URL del dashboard, se registra con el mismo email en Cognito, verifica el correo y queda habilitado como usuario read-only. Los usuarios read-only ven datos del dashboard pero no ven ni pueden usar la pestaña de invitaciones; eso es esperado, no un bug.

Para Google OAuth, configurar en Google Cloud el redirect URI de Cognito:

```text
https://itba-fraud-auth-<account-id>.auth.us-east-1.amazoncognito.com/oauth2/idpresponse
```

El dashboard incluye un modal de cuenta para cambiar contraseña en usuarios Cognito locales. Usuarios federados por Google no ven esa opción porque su contraseña se administra en Google.

**Endpoints de la API** (requieren un id-token de Cognito obtenido vía browser; no hay workflow para esto):

```bash
API=$(terraform output -raw api_endpoint)

curl -H "Authorization: Bearer <id-token>" "$API/health"
curl -H "Authorization: Bearer <id-token>" "$API/stats"
curl -H "Authorization: Bearer <id-token>" "$API/transactions?limit=10"
```

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
├── Makefile                 # Targets: init, plan, apply, destroy, build-layers, seed, send-test-tx, logs
├── .github/workflows/       # Validate, Plan, Docker, Apply, Destroy, Send test transactions
├── modules/
│   ├── network/             # VPC, subnets, VPN Gateway, VPC Endpoints
│   ├── queue/               # SQS ingesta + DLQ + CIDR lock on-prem
│   ├── data_store/          # DynamoDB + RDS + RDS Proxy + Secrets Manager
│   ├── compute/             # ECR + ECS Fargate + Auto Scaling
│   ├── onprem_sim/          # VPC on-prem + strongSwan EC2 + VPN site-to-site
│   ├── notification/        # SNS resumen + SQS alertas + Lambda summarizer
│   ├── results_writer/      # SQS resultados + Lambda writer (processor→SQS→Lambda→RDS)
│   ├── api/                 # Lambda API + HTTP API Gateway
│   └── dashboard/           # S3 bucket + website config + config.js templating
├── app/
│   ├── processor/           # Motor de scoring en Go (SQS consumer → SQS publishers)
│   ├── notification/        # Código Python de la Lambda summarizer de alertas
│   ├── api/                 # Dashboard API Lambda handler (Python)
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
